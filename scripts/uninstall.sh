#!/bin/bash
# Uninstalls macOS Lens: quits and removes the app, deletes its settings and web data, and resets its privacy
# permissions.
#
#   ./scripts/uninstall.sh [-y] [--keep-data] [--no-tcc-reset]
#   curl -fsSL https://raw.githubusercontent.com/SharonHart/macos-lens/main/scripts/uninstall.sh | bash -s -- -y
#
# Looks in /Applications and ~/Applications, or only in MACOS_LENS_INSTALL_DIR (or --dir) when set.
set -euo pipefail

BUNDLE_ID="dev.macos-lens.client"
DEBUG_NAME="MacOSLens" # settings and web data of the unbundled debug binary (.build/debug/MacOSLens)
APP_NAME="macOS Lens.app"

info() { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Uninstall macOS Lens.

Usage: ./scripts/uninstall.sh [options]

Options:
  -y, --yes        don't ask for confirmation
  --keep-data      keep settings, caches and web data
  --no-tcc-reset   keep the app's privacy permissions (Screen Recording)
  --dir <path>     only remove the app from <path> (same as MACOS_LENS_INSTALL_DIR)
  -h, --help       show this help
EOF
}

# Lists PIDs whose executable lives inside the given app bundle, never other copies of the app.
app_pids() {
    local app="$1" pattern pid command
    pattern="^$(printf '%s' "$app" | sed 's/[][\.*^$+?(){}|]/\\&/g')/Contents/MacOS/"
    for pid in $(pgrep -f "$pattern" || true); do
        command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
        if [[ "$command" == "$app/Contents/MacOS/"* ]]; then printf '%s\n' "$pid"; fi
    done
}

quit_app() {
    local app="$1" pids pid tries=0
    pids="$(app_pids "$app")"
    [[ -n "$pids" ]] || return 0
    info "Quitting $app..."
    for pid in $pids; do kill -TERM "$pid" 2>/dev/null || true; done
    while [[ -n "$(app_pids "$app")" ]] && ((tries < 20)); do
        sleep 0.5
        tries=$((tries + 1))
    done
    for pid in $(app_pids "$app"); do kill -KILL "$pid" 2>/dev/null || true; done
}

confirm() {
    local reply=""
    if ! { printf '%s [y/N] ' "$1" >/dev/tty; } 2>/dev/null; then
        die "No terminal to confirm on. Rerun with -y to uninstall without asking."
    fi
    read -r reply </dev/tty || true
    [[ "$reply" == [yY] || "$reply" == [yY][eE][sS] ]]
}

main() {
    local assume_yes=0 keep_data=0 tcc_reset=1 install_dir="${MACOS_LENS_INSTALL_DIR:-}"
    while (($#)); do
        case "$1" in
            -y | --yes) assume_yes=1 ;;
            --keep-data) keep_data=1 ;;
            --no-tcc-reset) tcc_reset=0 ;;
            --dir)
                [[ $# -ge 2 ]] || die "--dir needs a path."
                install_dir="$2"
                shift
                ;;
            --dir=*) install_dir="${1#--dir=}" ;;
            -h | --help) usage; exit 0 ;;
            *) die "Unknown option: $1 (see --help)" ;;
        esac
        shift
    done

    local dirs=() apps=() data=() domains=() dir path domain failed=0
    if [[ -n "$install_dir" ]]; then
        dirs=("${install_dir%/}")
    else
        dirs=(/Applications "$HOME/Applications")
    fi
    for dir in "${dirs[@]}"; do
        if [[ -d "$dir/$APP_NAME" ]]; then apps+=("$(cd "$dir" && pwd)/$APP_NAME"); fi
    done
    if ((!keep_data)); then
        for path in \
            "$HOME/Library/WebKit/$BUNDLE_ID" "$HOME/Library/WebKit/$DEBUG_NAME" \
            "$HOME/Library/Caches/$BUNDLE_ID" "$HOME/Library/Caches/$DEBUG_NAME" \
            "$HOME/Library/HTTPStorages/$BUNDLE_ID"* "$HOME/Library/HTTPStorages/$DEBUG_NAME"* \
            "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"; do
            if [[ -e "$path" ]]; then data+=("$path"); fi
        done
        for domain in "$BUNDLE_ID" "$DEBUG_NAME"; do
            if defaults read "$domain" >/dev/null 2>&1; then domains+=("$domain"); fi
        done
    fi

    if ((${#apps[@]} == 0 && ${#data[@]} == 0 && ${#domains[@]} == 0 && !tcc_reset)); then
        info "Nothing to remove: macOS Lens isn't installed in ${dirs[*]}."
        exit 0
    fi

    printf 'This will:\n'
    if ((${#apps[@]})); then
        for path in "${apps[@]}"; do printf '  - quit and remove %s\n' "$path"; done
    else
        printf '  - (no app found in %s)\n' "${dirs[*]}"
    fi
    if ((${#domains[@]})); then
        for domain in "${domains[@]}"; do printf '  - delete the settings (defaults domain %s)\n' "$domain"; done
    fi
    if ((${#data[@]})); then
        for path in "${data[@]}"; do printf '  - delete %s\n' "$path"; done
    fi
    ((tcc_reset)) && printf '  - reset its privacy permissions (Screen Recording)\n'
    if ((!assume_yes)) && ! confirm "Continue?"; then
        printf 'Cancelled; nothing was removed.\n'
        exit 1
    fi

    if ((${#apps[@]})); then
        for path in "${apps[@]}"; do
            quit_app "$path"
            if rm -rf "$path" 2>/dev/null && [[ ! -e "$path" ]]; then
                info "Removed $path"
            else
                warn "Could not remove $path. Move it to the Trash in Finder."
                failed=1
            fi
        done
    fi
    if ((${#domains[@]})); then
        for domain in "${domains[@]}"; do
            defaults delete "$domain" >/dev/null 2>&1 || true
            info "Deleted settings ($domain)"
        done
    fi
    if ((${#data[@]})); then
        for path in "${data[@]}"; do
            rm -rf "$path"
            info "Deleted $path"
        done
    fi
    if ((tcc_reset)); then
        /usr/bin/tccutil reset All "$BUNDLE_ID" >/dev/null 2>&1 || true
        info "Reset privacy permissions for $BUNDLE_ID"
    fi

    for path in /opt/homebrew /usr/local; do
        if [[ -d "$path/Caskroom/macos-lens" ]]; then
            printf 'Installed with Homebrew? Also run: brew uninstall --cask macos-lens\n'
        fi
        if [[ -d "$path/Cellar/macos-lens" ]]; then
            printf 'Installed with the old Homebrew formula? Also run: brew uninstall macos-lens\n'
        fi
    done
    ((failed)) && exit 1
    printf 'macOS Lens is uninstalled.\n'
}

main "$@"

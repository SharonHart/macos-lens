#!/bin/bash
# Installs or updates macOS Lens.
#
#   curl -fsSL https://raw.githubusercontent.com/SharonHart/macos-lens/main/scripts/install.sh | bash
#   ./scripts/install.sh [--dir <path>] [--no-launch]
#
# This downloads the latest prebuilt release, verifies its checksum and signature, and installs it to
# /Applications (or ~/Applications when /Applications isn't writable). Nothing is sent anywhere except the
# GitHub downloads. (Maintainers: --from-source builds the checkout instead, and is used when no release exists.)
#
# Environment:
#   GITHUB_TOKEN (or GH_TOKEN)      optional; only raises GitHub's API rate limit (downloads are anonymous)
#   MACOS_LENS_INSTALL_DIR=<dir>    install into <dir> instead of /Applications
#   MACOS_LENS_RELEASE_ZIP=<zip>    install this release zip instead of downloading (checked against a
#                                   SHA256SUMS file next to it when present)
#   MACOS_LENS_SKIP_LAUNCH=1        same as --no-launch
#
# Privacy permissions are left alone: the app asks for Screen Recording only when its button is clicked.
set -euo pipefail

REPO="SharonHart/macos-lens"
BUNDLE_ID="dev.macos-lens.client"
APP_NAME="macOS Lens.app"

SCRIPT_PATH="${BASH_SOURCE[0]:-}"
LOCAL_ROOT=""
if [[ -n "$SCRIPT_PATH" && -f "$SCRIPT_PATH" ]]; then
    candidate="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"
    if [[ -f "$candidate/Package.swift" && -f "$candidate/scripts/build-app.sh" ]]; then LOCAL_ROOT="$candidate"; fi
fi

WORK=""
STAGING=""
SOURCE_ROOT=""
NEW_APP=""
DEST_APP=""
DOWNLOADED_ZIP=""

info() { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

cleanup() {
    if [[ -n "$STAGING" ]]; then rm -rf "$STAGING"; fi
    if [[ -n "$WORK" ]]; then rm -rf "$WORK"; fi
}

usage() {
    cat <<'EOF'
Install or update macOS Lens.

Usage:
  curl -fsSL https://raw.githubusercontent.com/SharonHart/macos-lens/main/scripts/install.sh | bash
  curl -fsSL https://raw.githubusercontent.com/SharonHart/macos-lens/main/scripts/install.sh | bash -s -- [options]
  ./scripts/install.sh [options]

Options:
  --dir <path>     install into <path> instead of /Applications (or ~/Applications)
  --no-launch      don't open the app after installing
  -h, --help       show this help
EOF
}

check_macos() {
    local version major
    version="$(sw_vers -productVersion)"
    major="${version%%.*}"
    [[ "$major" =~ ^[0-9]+$ ]] && ((major >= 14)) ||
        die "macOS Lens needs macOS 14 Sonoma or newer; this Mac runs macOS $version."
}

json_value() { # <file> <key path>: prints a value from GitHub's JSON with plutil (no jq needed)
    plutil -extract "$2" raw -o - "$1" 2>/dev/null
}

checksum_ok() { # <file> <SHA256SUMS>
    local name expected actual
    name="$(basename "$1")"
    expected="$(awk -v n="$name" '$2 == n || $2 == "*" n { print $1; exit }' "$2")"
    [[ -n "$expected" ]] || die "$(basename "$2") has no entry for $name."
    actual="$(shasum -a 256 "$1" | awk '{ print $1 }')"
    [[ "$expected" == "$actual" ]] || die "Checksum mismatch for $name (expected $expected, got $actual). Not installing."
    info "Checksum verified for $name."
}

# Downloads into $WORK/download and sets DOWNLOADED_ZIP. Returns 1 when gh isn't usable or has no release for us.
download_with_gh() {
    command -v gh >/dev/null 2>&1 || return 1
    # `gh auth status` fails if any saved account is broken, so ask for the github.com token instead.
    gh auth token --hostname github.com >/dev/null 2>&1 || return 1
    info "Downloading the latest release with gh..."
    rm -rf "$WORK/download" && mkdir -p "$WORK/download"
    if ! gh release download -R "$REPO" -p 'macOS-Lens-*.zip' -p SHA256SUMS -D "$WORK/download" </dev/null; then
        warn "gh could not download a release from $REPO."
        return 1
    fi
    find_download
}

find_download() {
    DOWNLOADED_ZIP="$(find "$WORK/download" -maxdepth 1 -name 'macOS-Lens-*.zip' | head -n 1)"
    [[ -n "$DOWNLOADED_ZIP" ]] || return 1
    [[ -f "$WORK/download/SHA256SUMS" ]] || die "The release has no SHA256SUMS file, so it can't be verified."
}

# Downloads into $WORK/download and sets DOWNLOADED_ZIP. Returns 1 when there's no release (404 or no assets).
download_with_curl() {
    local token="${GITHUB_TOKEN:-${GH_TOKEN:-}}" json="$WORK/release.json" headers="$WORK/headers" code
    local count i name api_url web_url zip_name="" zip_api="" zip_web="" sums_api="" sums_web=""
    (umask 077 && : >"$headers")
    if [[ -n "$token" ]]; then printf 'Authorization: Bearer %s\n' "$token" >"$headers"; fi
    info "Looking up the latest release of $REPO..."
    code="$(curl -sS -L -o "$json" -w '%{http_code}' -H @"$headers" -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/$REPO/releases/latest")" || die "Could not reach api.github.com."
    case "$code" in
        200) ;;
        404) return 1 ;;
        401) die "GitHub rejected GITHUB_TOKEN (HTTP 401). Check it, or unset it to download anonymously." ;;
        403 | 429) die "GitHub refused the request (HTTP $code, probably a rate limit). Set GITHUB_TOKEN or try again later." ;;
        *) die "Unexpected response from GitHub (HTTP $code)." ;;
    esac
    # Older plutil versions reject JSON nulls; release metadata doesn't need them.
    sed -E 's/:[[:space:]]*null/:""/g' "$json" >"$json.clean"
    count="$(json_value "$json.clean" assets || echo 0)"
    i=0
    while ((i < count)); do
        name="$(json_value "$json.clean" "assets.$i.name" || true)"
        api_url="$(json_value "$json.clean" "assets.$i.url" || true)"
        web_url="$(json_value "$json.clean" "assets.$i.browser_download_url" || true)"
        case "$name" in
            macOS-Lens-*.zip) zip_name="$name" zip_api="$api_url" zip_web="$web_url" ;;
            SHA256SUMS) sums_api="$api_url" sums_web="$web_url" ;;
        esac
        i=$((i + 1))
    done
    [[ -n "$zip_name" ]] || return 1
    [[ -n "$sums_api" ]] || die "The latest release has no SHA256SUMS file, so it can't be verified."
    info "Downloading $zip_name ($(json_value "$json.clean" tag_name || echo latest))..."
    rm -rf "$WORK/download" && mkdir -p "$WORK/download"
    fetch_asset "$token" "$zip_api" "$zip_web" "$WORK/download/$zip_name"
    fetch_asset "$token" "$sums_api" "$sums_web" "$WORK/download/SHA256SUMS"
    DOWNLOADED_ZIP="$WORK/download/$zip_name"
}

fetch_asset() { # <token> <api url> <browser url> <destination>
    if [[ -n "$1" ]]; then
        # The API URL works for private repositories; curl drops the token when GitHub redirects to storage.
        curl -fsSL -H @"$WORK/headers" -H 'Accept: application/octet-stream' -o "$4" "$2" ||
            die "Download failed: $(basename "$4")"
    else
        curl -fsSL -o "$4" "$3" || die "Download failed: $(basename "$4")"
    fi
}

# Sets NEW_APP to the unpacked, verified app from a release zip.
unpack_release() { # <zip> [SHA256SUMS]
    local zip="$1" sums="${2:-}"
    if [[ -n "$sums" && -f "$sums" ]]; then
        checksum_ok "$zip" "$sums"
    else
        warn "No SHA256SUMS next to $(basename "$zip"); skipping the checksum check."
    fi
    rm -rf "$WORK/unpacked" && mkdir -p "$WORK/unpacked"
    ditto -x -k "$zip" "$WORK/unpacked" || die "Could not unpack $(basename "$zip")."
    NEW_APP="$WORK/unpacked/$APP_NAME"
    [[ -d "$NEW_APP" ]] || die "$(basename "$zip") doesn't contain $APP_NAME."
}

host_arch() {
    if [[ "$(sysctl -in hw.optional.arm64)" == 1 ]]; then echo arm64; else echo x86_64; fi
}

ensure_toolchain() {
    if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swift >/dev/null 2>&1; then
        warn "Building from source needs the Xcode Command Line Tools, which aren't installed."
        xcode-select --install >/dev/null 2>&1 || true
        die "Finish installing the Command Line Tools in the dialog that opened, then run this installer again."
    fi
    local version major minor
    version="$(xcrun swift --version 2>/dev/null | sed -n 's/.*Swift version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n 1)"
    major="${version%%.*}"
    minor="${version#*.}"
    if [[ -z "$version" ]] || ((major < 5 || (major == 5 && minor < 10))); then
        die "macOS Lens needs Swift 5.10 or newer (found ${version:-none}). Update the Command Line Tools in System Settings › General › Software Update."
    fi
    info "Using Swift $version."
}

# Sets NEW_APP to a freshly built app.
build_from_source() {
    ensure_toolchain
    if [[ -n "$LOCAL_ROOT" ]]; then
        SOURCE_ROOT="$LOCAL_ROOT"
    else
        info "Cloning $REPO..."
        git clone --quiet --depth 1 "https://github.com/$REPO.git" "$WORK/source" ||
            die "Could not clone $REPO."
        SOURCE_ROOT="$WORK/source"
    fi
    info "Building from $SOURCE_ROOT (this takes a minute or two)..."
    NEW_APP="$WORK/build/$APP_NAME"
    mkdir -p "$WORK/build"
    MACOS_LENS_APP="$NEW_APP" bash "$SOURCE_ROOT/scripts/build-app.sh" ||
        die "The build failed."
    # Checkouts whose build script predates MACOS_LENS_APP build into dist/.
    if [[ ! -d "$NEW_APP" ]]; then NEW_APP="$SOURCE_ROOT/dist/$APP_NAME"; fi
    [[ -d "$NEW_APP" ]] || die "The build didn't produce $APP_NAME."
}

choose_destination() {
    local dir
    if [[ -n "${MACOS_LENS_INSTALL_DIR:-}" ]]; then
        mkdir -p "$MACOS_LENS_INSTALL_DIR" || die "Can't create $MACOS_LENS_INSTALL_DIR."
        dir="$(cd "$MACOS_LENS_INSTALL_DIR" && pwd)"
    elif [[ -d "$HOME/Applications/$APP_NAME" && ! -d "/Applications/$APP_NAME" ]]; then
        dir="$HOME/Applications"
    elif [[ -w /Applications ]]; then
        dir="/Applications"
    else
        dir="$HOME/Applications"
        mkdir -p "$dir"
        info "/Applications isn't writable without admin rights; installing to $dir."
    fi
    DEST_APP="$dir/$APP_NAME"
}

cdhash() {
    codesign -d -vvv "$1" 2>&1 | sed -n 's/^CDHash=//p' | head -n 1
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
    info "Quitting the running copy of $app..."
    for pid in $pids; do kill -TERM "$pid" 2>/dev/null || true; done
    while [[ -n "$(app_pids "$app")" ]] && ((tries < 20)); do
        sleep 0.5
        tries=$((tries + 1))
    done
    for pid in $(app_pids "$app"); do kill -KILL "$pid" 2>/dev/null || true; done
}

# Installs NEW_APP at DEST_APP, unless the same build is already there.
install_app() {
    local identifier version
    identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$NEW_APP/Contents/Info.plist" 2>/dev/null || true)"
    [[ "$identifier" == "$BUNDLE_ID" ]] || die "Unexpected bundle identifier '$identifier'. Not installing."
    codesign --verify --deep --strict "$NEW_APP" || die "The app's code signature is invalid. Not installing."
    version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$NEW_APP/Contents/Info.plist")"

    choose_destination
    if [[ -d "$DEST_APP" ]] && codesign --verify --deep --strict "$DEST_APP" >/dev/null 2>&1 &&
        [[ "$(cdhash "$DEST_APP")" == "$(cdhash "$NEW_APP")" ]]; then
        info "macOS Lens $version is already installed at $DEST_APP."
        return 0
    fi

    info "Installing macOS Lens $version to $DEST_APP..."
    STAGING="$(dirname "$DEST_APP")/.$APP_NAME.installing.$$"
    rm -rf "$STAGING"
    ditto "$NEW_APP" "$STAGING" || die "Could not copy the app into $(dirname "$DEST_APP")."
    quit_app "$DEST_APP"
    if [[ -e "$DEST_APP" ]]; then
        rm -rf "$DEST_APP" || die "Could not replace $DEST_APP. Move it to the Trash and run the installer again."
    fi
    mv "$STAGING" "$DEST_APP"
    STAGING=""
    codesign --verify --deep --strict "$DEST_APP" || die "The installed app failed signature verification."
}

shortcut_titles() { # <array name in Shortcut.swift>: prints its titles, one per line
    local root="${SOURCE_ROOT:-$LOCAL_ROOT}" file
    file="$root/Sources/LensCore/Shortcut.swift"
    [[ -n "$root" && -f "$file" ]] || return 0
    awk -v name="$1" '
        $0 ~ "static let " name " = \\[" { inside = 1; next }
        inside && /^[[:space:]]*\]/ { exit }
        inside && /title: "/ { sub(/.*title: "/, ""); sub(/".*/, ""); print }
    ' "$file"
}

print_shortcuts() {
    local search text fallbacks
    search="$(shortcut_titles all | head -n 1)"
    text="$(shortcut_titles textOptions | head -n 1)"
    fallbacks="$(shortcut_titles textOptions | sed 1d | paste -sd '/' - | sed 's|/| or |g')"
    printf '\nKeyboard shortcuts (change them in macOS Lens Settings):\n'
    printf '  Search or select text:  %s\n' "${search:-Command + Shift + 2}"
    printf '  Select all text:        %s (uses %s if macOS already has that one)\n' \
        "${text:-Command + Shift + 1}" "${fallbacks:-Control + Shift + 1 or Control + Option + T}"
}

main() {
    local from_source=0 launch=1 zip=""
    [[ "${MACOS_LENS_SKIP_LAUNCH:-0}" == 1 ]] && launch=0
    while (($#)); do
        case "$1" in
            --from-source) from_source=1 ;;
            --no-launch) launch=0 ;;
            --no-tcc-reset) ;; # Accepted for older instructions; nothing is reset any more.
            --dir)
                [[ $# -ge 2 ]] || die "--dir needs a path."
                MACOS_LENS_INSTALL_DIR="$2"
                shift
                ;;
            --dir=*) MACOS_LENS_INSTALL_DIR="${1#--dir=}" ;;
            -h | --help) usage; exit 0 ;;
            *) die "Unknown option: $1 (see --help)" ;;
        esac
        shift
    done

    check_macos
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/macos-lens-install.XXXXXX")"
    trap cleanup EXIT
    trap 'exit 130' INT TERM

    if ((from_source)); then
        build_from_source
    elif [[ -n "${MACOS_LENS_RELEASE_ZIP:-}" ]]; then
        zip="$MACOS_LENS_RELEASE_ZIP"
        [[ -f "$zip" ]] || die "MACOS_LENS_RELEASE_ZIP points to a missing file: $zip"
        info "Installing from $zip"
        unpack_release "$zip" "$(dirname "$zip")/SHA256SUMS"
    elif download_with_gh || download_with_curl; then
        unpack_release "$DOWNLOADED_ZIP" "$WORK/download/SHA256SUMS"
    else
        warn "No prebuilt release found."
        info "Building from source instead."
        build_from_source
    fi

    if ! lipo -archs "$NEW_APP/Contents/MacOS/MacOSLens" | grep -qw "$(host_arch)"; then
        ((from_source)) && die "The built app doesn't support this Mac ($(host_arch))."
        warn "This release doesn't include a $(host_arch) build; building from source instead."
        from_source=1
        build_from_source
    fi

    install_app

    printf '\nmacOS Lens is installed at %s\n' "$DEST_APP"
    print_shortcuts
    if ((launch)); then
        open "$DEST_APP"
        printf '\nmacOS Lens is opening. When it shows its Screen Recording window, click Allow Screen Recording…,\n'
        printf 'turn macOS Lens on in System Settings, then choose Quit & Reopen.\n'
    else
        printf '\nOpen it with: open "%s"\n' "$DEST_APP"
    fi
}

main "$@"

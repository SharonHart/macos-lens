#!/bin/bash
# Notarizes a Developer ID-signed app or disk image with Apple, staples the ticket to it and checks it with Gatekeeper.
#
#   scripts/notarize.sh <path/to/macOS Lens.app | path/to/image.dmg>
#
# scripts/package.sh and scripts/make-dmg.sh call it when notarization credentials are set. Use one of:
#   MACOS_LENS_NOTARY_PROFILE=<name>        a keychain profile saved with `xcrun notarytool store-credentials`
#   MACOS_LENS_NOTARY_KEY=<AuthKey_X.p8>    an App Store Connect team API key, with MACOS_LENS_NOTARY_KEY_ID and
#                                           MACOS_LENS_NOTARY_ISSUER (the release workflow uses this one)
#
# The submission ID is printed before the wait. If Apple takes longer than 30 minutes, check it later with
# `xcrun notarytool info <id>` instead of submitting again.
set -euo pipefail
cd "$(dirname "$0")/.."

step() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

TARGET="${1:-}"
TARGET="${TARGET%/}"
[[ -e "$TARGET" ]] || die "Usage: $0 <path/to/app.app | path/to/image.dmg>"
case "$TARGET" in
    *.app) KIND=app ;;
    *.dmg) KIND=dmg ;;
    *) die "$TARGET is neither an .app nor a .dmg." ;;
esac

if [[ -n "${MACOS_LENS_NOTARY_PROFILE:-}" ]]; then
    AUTH=(--keychain-profile "$MACOS_LENS_NOTARY_PROFILE")
elif [[ -n "${MACOS_LENS_NOTARY_KEY:-}" ]]; then
    [[ -f "$MACOS_LENS_NOTARY_KEY" ]] || die "MACOS_LENS_NOTARY_KEY ($MACOS_LENS_NOTARY_KEY) isn't a file."
    [[ -n "${MACOS_LENS_NOTARY_KEY_ID:-}" && -n "${MACOS_LENS_NOTARY_ISSUER:-}" ]] ||
        die "Set MACOS_LENS_NOTARY_KEY_ID and MACOS_LENS_NOTARY_ISSUER with MACOS_LENS_NOTARY_KEY."
    AUTH=(--key "$MACOS_LENS_NOTARY_KEY" --key-id "$MACOS_LENS_NOTARY_KEY_ID" --issuer "$MACOS_LENS_NOTARY_ISSUER")
else
    die "Set MACOS_LENS_NOTARY_PROFILE, or MACOS_LENS_NOTARY_KEY with MACOS_LENS_NOTARY_KEY_ID and MACOS_LENS_NOTARY_ISSUER."
fi

# Apple only notarizes code signed with a Developer ID, a secure timestamp and, for apps, the Hardened Runtime.
SIGNATURE="$(codesign --display --verbose=4 "$TARGET" 2>&1)" || die "$TARGET isn't signed."
grep -q '^Authority=Developer ID Application: ' <<<"$SIGNATURE" || die "$TARGET isn't signed with a Developer ID."
grep -q '^Timestamp=' <<<"$SIGNATURE" || die "$TARGET's signature has no secure timestamp."
if [[ "$KIND" == app ]]; then
    grep -Eq '^CodeDirectory .*flags=.*\(.*runtime' <<<"$SIGNATURE" || die "$TARGET isn't signed with the Hardened Runtime."
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/macos-lens-notarize.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
UPLOAD="$TARGET"
if [[ "$KIND" == app ]]; then
    UPLOAD="$WORK/$(basename "$TARGET" .app).zip"
    ditto -c -k --sequesterRsrc --keepParent "$TARGET" "$UPLOAD"
fi

step "Submitting $(basename "$TARGET") for notarization"
xcrun notarytool submit "$UPLOAD" "${AUTH[@]}" --output-format json >"$WORK/submit.json"
ID="$(plutil -extract id raw -o - "$WORK/submit.json" 2>/dev/null || true)"
[[ "$ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
    die "Apple returned no submission ID. Look for the upload with \`xcrun notarytool history\` before submitting again."
printf 'Submission ID: %s. Waiting up to 30 minutes for Apple.\n' "$ID"
# wait's own exit status isn't the verdict; info below is.
xcrun notarytool wait "$ID" "${AUTH[@]}" --timeout 30m >/dev/null || true
xcrun notarytool info "$ID" "${AUTH[@]}" --output-format json >"$WORK/info.json"
STATUS="$(plutil -extract status raw -o - "$WORK/info.json" 2>/dev/null || true)"
if [[ "$STATUS" != Accepted ]]; then
    xcrun notarytool log "$ID" "${AUTH[@]}" >&2 || true
    die "Notarization was not accepted (${STATUS:-no status}). Submission ID: $ID"
fi

step "Stapling and checking $(basename "$TARGET")"
xcrun stapler staple -q "$TARGET"
xcrun stapler validate -q "$TARGET"
if [[ "$KIND" == app ]]; then
    spctl --assess --type execute --verbose "$TARGET"
else
    spctl --assess --type open --context context:primary-signature --verbose "$TARGET"
fi

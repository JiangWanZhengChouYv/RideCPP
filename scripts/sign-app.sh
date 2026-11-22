#!/bin/bash
# Signs RideCPP.app for distribution.
#
# With a Developer ID Application identity (env DEV_ID or the only one installed)
# it signs for notarization with the hardened runtime. Without one it falls back
# to an ad-hoc signature, which is fine for this Mac and for local testing but is
# rejected by Gatekeeper on other machines.
#
# Usage: scripts/sign-app.sh path/to/RideCPP.app

set -euo pipefail

APP="${1:?usage: sign-app.sh path/to/RideCPP.app}"
[ -d "$APP" ] || { echo "not an app bundle: $APP" >&2; exit 1; }

find_identity() {
    if [ -n "${DEV_ID:-}" ]; then
        printf '%s\n' "$DEV_ID"
        return 0
    fi
    security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' \
        | head -1
}

IDENTITY="$(find_identity || true)"

sign_bundle() {
    local bundle="$1"
    local identity="$2"
    if [ "$identity" = "-" ]; then
        codesign --force --sign - "$bundle"
    else
        codesign --force --options runtime --timestamp --sign "$identity" "$bundle"
    fi
}

if [ -n "$IDENTITY" ]; then
    echo "Signing with: $IDENTITY"
    # Nested frameworks first: signing the app last seals them correctly.
    for framework in "$APP"/Contents/Frameworks/*.framework; do
        [ -d "$framework" ] || continue
        sign_bundle "$framework" "$IDENTITY"
    done
    sign_bundle "$APP" "$IDENTITY"
    codesign --verify --deep --strict --verbose=2 "$APP"
    echo "Signed with a Developer ID (hardened runtime, notarizable)."
else
    echo "No Developer ID Application certificate found; signing ad-hoc."
    echo "This build runs on this Mac, but Gatekeeper will block it on other Macs."
    for framework in "$APP"/Contents/Frameworks/*.framework; do
        [ -d "$framework" ] || continue
        sign_bundle "$framework" "-"
    done
    sign_bundle "$APP" "-"
    codesign --verify --deep --strict "$APP"
    echo "Ad-hoc signature applied."
fi

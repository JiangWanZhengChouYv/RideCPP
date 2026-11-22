#!/bin/bash
# Notarizes a RideCPP disk image and staples the ticket so it opens cleanly on
# other Macs.
#
# Requires an Apple Developer Program membership and a "Developer ID Application"
# certificate installed in the login keychain. Credentials are read from the
# environment (never passed on the command line, so they do not end up in shell
# history):
#
#   APPLE_ID       your Apple ID e-mail
#   TEAM_ID        your 10-character Team ID
#   APP_PASSWORD   an app-specific password from appleid.apple.com
#
# or, if you stored a notarytool profile once:
#
#   NOTARY_PROFILE ridecpp
#
# Usage: scripts/notarize.sh dist/RideCPP-1.0-arm64-x86_64.dmg

set -euo pipefail

DMG="${1:?usage: notarize.sh path/to/RideCPP.dmg}"
[ -f "$DMG" ] || { echo "no such disk image: $DMG" >&2; exit 1; }

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    cat >&2 <<'MSG'
No "Developer ID Application" certificate is installed.

Distributing to other Macs requires an Apple Developer Program membership:
  1. Enroll at https://developer.apple.com/programs/
  2. In Xcode → Settings → Accounts → Manage Certificates, create a
     "Developer ID Application" certificate.
  3. Re-run `make dist`, then this script.
MSG
    exit 1
fi

if [ -n "${NOTARY_PROFILE:-}" ]; then
    AUTH=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${APPLE_ID:-}" ] && [ -n "${TEAM_ID:-}" ] && [ -n "${APP_PASSWORD:-}" ]; then
    AUTH=(--apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD")
else
    cat >&2 <<'MSG'
No notarization credentials found.

Set either:
  NOTARY_PROFILE=<profile>   (create once with:
                              xcrun notarytool store-credentials ridecpp \
                                --apple-id you@example.com --team-id TEAMID \
                                --password <app-specific-password>)
or all three of APPLE_ID, TEAM_ID and APP_PASSWORD.
MSG
    exit 1
fi

echo "Submitting $DMG for notarization…"
xcrun notarytool submit "$DMG" "${AUTH[@]}" --wait

echo "Stapling the notarization ticket…"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo
echo "Notarized: $DMG"
echo "Verify on another Mac with: spctl -a -t open --context context:primary-signature -vv \"$DMG\""

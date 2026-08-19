#!/usr/bin/env bash
#
# Archives, exports and uploads a build to TestFlight.
#
#   Tools/testflight.sh            # archive + export, stop before upload
#   Tools/testflight.sh --upload   # and upload to App Store Connect
#
# Needs, once:
#   - The app registered in App Store Connect against com.rrochlin.LiftingCoach.
#     A build for an unregistered app is rejected at upload with "No suitable
#     application records were found."
#   - An App Store Connect API key (Users and Access > Integrations), with the
#     .p8 saved as ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8. A key is
#     used rather than an app-specific password so no secret is ever typed on a
#     command line.
#   - ASC_KEY_ID / ASC_ISSUER_ID. Put them in
#     ~/.appstoreconnect/credentials.env, which this script sources when it
#     exists — beside the key they belong to, and outside any repo. Exporting
#     them in the environment works too, which is how CI supplies them.
#
# The build number is the commit count, so it rises on its own and can't
# collide with one already uploaded. The marketing version comes from
# project.yml.
set -euo pipefail

cd "$(dirname "$0")/.."

TEAM_ID=33G44VZ97Z
BUILD_DIR=/tmp/lifting-coach-archive
ARCHIVE="$BUILD_DIR/LiftingCoach.xcarchive"
BUILD_NUMBER=$(git rev-list --count HEAD)

if [[ -n "$(git status --porcelain)" ]]; then
    # Not fatal — but a TestFlight build that doesn't match a commit is one you
    # can't come back to when a tester reports something.
    echo "warning: working tree is dirty; this build won't match any commit" >&2
fi

echo "==> build $BUILD_NUMBER (commit $(git rev-parse --short HEAD))"

xcodegen generate
rm -rf "$BUILD_DIR"

xcodebuild -project LiftingCoach.xcodeproj -scheme LiftingCoach \
    -configuration Release -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$TEAM_ID" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    archive

cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>teamID</key><string>$TEAM_ID</string>
	<key>signingStyle</key><string>automatic</string>
	<key>uploadSymbols</key><true/>
	<key>destination</key><string>export</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportPath "$BUILD_DIR/export" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
    -allowProvisioningUpdates

IPA="$BUILD_DIR/export/LiftingCoach.ipa"
echo "==> exported $IPA"

if [[ "${1:-}" != "--upload" ]]; then
    echo "==> stopping before upload; re-run with --upload to send it"
    exit 0
fi

# Sourced late, so an already-exported value (CI, or a one-off on the command
# line) wins over the file rather than being silently overwritten by it.
CREDENTIALS="$HOME/.appstoreconnect/credentials.env"
if [[ -z "${ASC_KEY_ID:-}" || -z "${ASC_ISSUER_ID:-}" ]] && [[ -f "$CREDENTIALS" ]]; then
    # shellcheck source=/dev/null
    source "$CREDENTIALS"
fi

: "${ASC_KEY_ID:?set ASC_KEY_ID, or put it in ~/.appstoreconnect/credentials.env}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID, or put it in ~/.appstoreconnect/credentials.env}"

xcrun altool --validate-app -f "$IPA" -t ios \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
xcrun altool --upload-app -f "$IPA" -t ios \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo "==> uploaded. Processing takes a few minutes; TestFlight will email when"
echo "    build $BUILD_NUMBER is ready to install."

#!/usr/bin/env bash
#
# Archives, exports and uploads a build to TestFlight.
#
#   Tools/testflight.sh                           # archive + export, stop before upload
#   Tools/testflight.sh --upload                  # and upload — a new marketing version
#   Tools/testflight.sh --upload --same-version   # another build of the current one
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
# The build number defaults to the commit count, and with --upload it is
# checked against App Store Connect *before* archiving. The count alone used to
# be the whole story, on the claim that a number derived from history "can't
# collide with one already uploaded". That holds on one branch and fails across
# them: `git rev-list --count HEAD` counts the branch you're on, so two branches
# reach the same number with different code, and a branch that's behind another
# produces a number lower than one already shipped. Build 72 was cut from a
# feature branch while main counted differently, and nothing noticed. So:
#
#   - Tools/asc-latest-build.py asks App Store Connect for the highest build
#     already uploaded, and this refuses anything not above it — in seconds,
#     rather than after a full archive has been built and rejected.
#   - BUILD_NUMBER=<n> overrides the count for the one case it's wrong (shipping
#     from a branch behind main). It goes through the same check.
#   - The commit is stamped into Info.plist as LCGitCommit and shown on Profile,
#     so any installed build can say which code it is. That was the question
#     that couldn't be answered about build 68.
#
# The marketing version comes from project.yml (MARKETING_VERSION), and with
# --upload every build has to decide what it is. App Store Connect is asked for
# the highest version already uploaded:
#
#   - Lower than that is refused — versions only go forward.
#   - The same is refused unless --same-version says this is another build of
#     that release. The build number moved on every upload for a month while
#     the version sat at 0.1.0, because nothing ever asked; this is the asking.
#   - Higher is a new release and goes through.
#
# Semantic versions, decided by what a lifter would notice: the minor for new
# features or behaviour (0.2.0 was cloud backup and Sign in with Apple), the
# patch for fixes only, 1.0.0 for the App Store launch. Bump it in project.yml
# in the PR that makes the release, so the version change is reviewed with the
# work it names.
set -euo pipefail

cd "$(dirname "$0")/.."

TEAM_ID=33G44VZ97Z
BUILD_DIR=/tmp/lifting-coach-archive
ARCHIVE="$BUILD_DIR/LiftingCoach.xcarchive"
BUNDLE_ID=com.rrochlin.LiftingCoach
BUILD_NUMBER=${BUILD_NUMBER:-$(git rev-list --count HEAD)}
COMMIT=$(git rev-parse --short HEAD)
UPLOAD=false
SAME_VERSION=false
for arg in "$@"; do
    case "$arg" in
        --upload) UPLOAD=true ;;
        --same-version) SAME_VERSION=true ;;
        *) echo "error: unknown argument $arg" >&2; exit 2 ;;
    esac
done

VERSION=$(sed -nE 's/^ *MARKETING_VERSION: *"?([0-9]+\.[0-9]+\.[0-9]+)"?.*/\1/p' project.yml | head -1)
if [[ -z "$VERSION" ]]; then
    echo "error: no x.y.z MARKETING_VERSION in project.yml" >&2
    exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
    # Not fatal — but a TestFlight build that doesn't match a commit is one you
    # can't come back to when a tester reports something. The stamp says so
    # rather than naming a commit the binary doesn't actually match.
    echo "warning: working tree is dirty; this build won't match any commit" >&2
    COMMIT="$COMMIT-dirty"
fi

if $UPLOAD; then
    # Sourced before anything is built, so a missing credential or a build
    # number App Store Connect will refuse fails now rather than after the
    # archive. An already-exported value (CI, or a one-off on the command line)
    # wins over the file rather than being silently overwritten by it.
    CREDENTIALS="$HOME/.appstoreconnect/credentials.env"
    if [[ -z "${ASC_KEY_ID:-}" || -z "${ASC_ISSUER_ID:-}" ]] && [[ -f "$CREDENTIALS" ]]; then
        # shellcheck source=/dev/null
        source "$CREDENTIALS"
    fi
    : "${ASC_KEY_ID:?set ASC_KEY_ID, or put it in ~/.appstoreconnect/credentials.env}"
    : "${ASC_ISSUER_ID:?set ASC_ISSUER_ID, or put it in ~/.appstoreconnect/credentials.env}"
    export ASC_KEY_ID ASC_ISSUER_ID

    LATEST=$(Tools/asc-latest-build.py "$BUNDLE_ID")
    if (( BUILD_NUMBER <= LATEST )); then
        echo "error: build $BUILD_NUMBER is not above $LATEST, the highest already in App Store Connect." >&2
        echo "  The build number is the commit count of the branch you're on, so this" >&2
        echo "  usually means the branch is behind the one the last build came from." >&2
        echo "  Ship from an up-to-date main, or override: BUILD_NUMBER=$((LATEST + 1)) $0 --upload" >&2
        exit 1
    fi
    echo "==> App Store Connect is at build $LATEST; $BUILD_NUMBER is clear"

    SHIPPED=$(Tools/asc-latest-build.py --marketing "$BUNDLE_ID")
    # `sort -V` orders version strings component by component.
    HIGHEST=$(printf '%s\n%s\n' "$SHIPPED" "$VERSION" | sort -V | tail -1)
    if [[ "$VERSION" != "$HIGHEST" ]]; then
        echo "error: version $VERSION is below $SHIPPED, already in App Store Connect." >&2
        exit 1
    fi
    if [[ "$VERSION" == "$SHIPPED" ]] && ! $SAME_VERSION; then
        echo "error: $VERSION is already in App Store Connect." >&2
        echo "  A new release? Bump MARKETING_VERSION in project.yml — minor for" >&2
        echo "  features, patch for fixes. Another build of $VERSION? Add --same-version." >&2
        exit 1
    fi
    echo "==> App Store Connect is at version $SHIPPED; shipping $VERSION"
fi

echo "==> version $VERSION, build $BUILD_NUMBER (commit $COMMIT)"

xcodegen generate
rm -rf "$BUILD_DIR"

xcodebuild -project LiftingCoach.xcodeproj -scheme LiftingCoach \
    -configuration Release -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$TEAM_ID" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    MARKETING_VERSION="$VERSION" \
    LC_GIT_COMMIT="$COMMIT" \
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

if ! $UPLOAD; then
    echo "==> stopping before upload; re-run with --upload to send it"
    exit 0
fi

xcrun altool --validate-app -f "$IPA" -t ios \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
xcrun altool --upload-app -f "$IPA" -t ios \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo "==> uploaded. Processing takes a few minutes; TestFlight will email when"
echo "    build $BUILD_NUMBER is ready to install."

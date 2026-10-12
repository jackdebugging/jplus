#!/bin/zsh
# Archives JPlus for iPhone and iPad and uploads it to App Store Connect,
# where it shows up in TestFlight and can be submitted for review.
#
# Signed by team 89V5HKLEV9 (sichengxu@gmail.com), the Apple ID that must
# be signed into Xcode › Settings › Accounts. Xcode creates the Apple
# Distribution certificate and the App Store profile on first use.
#
# One-time setup: create the app in App Store Connect (My Apps › + › New App)
# with bundle ID com.hannagrove.jplus.ios. Uploads fail until it exists.
#
# The version is the project's Marketing Version, shared with the Mac app;
# the build number is the commit count, so every upload from a new commit
# gets a higher one, as App Store Connect requires.
#
# Usage: scripts/release-ios.sh [--export-only]
#   --export-only  sign build/ios-export/JPlus.ipa for the App Store but don't
#                  upload it, to check signing before the app record exists.
set -euo pipefail

cd "$(dirname "$0")/.."
TEAM=89V5HKLEV9
BUILD=build
ARCHIVE="$BUILD/JPlus-iOS.xcarchive"
EXPORT="$BUILD/ios-export"
OPTIONS=scripts/ExportOptions-AppStore.plist
BUILD_NUMBER=$(git rev-list --count HEAD)

if [[ -n "$(git status --porcelain -- JPlus JPlus.xcodeproj)" ]]; then
    echo "The app has uncommitted changes; commit them so the build number names this build." >&2
    exit 1
fi

if [[ "${1:-}" == "--export-only" ]]; then
    mkdir -p "$BUILD"
    cp "$OPTIONS" "$BUILD/ExportOptions-AppStore-export.plist"
    /usr/libexec/PlistBuddy -c "Set :destination export" "$BUILD/ExportOptions-AppStore-export.plist"
    OPTIONS="$BUILD/ExportOptions-AppStore-export.plist"
fi

rm -rf "$ARCHIVE" "$EXPORT"
mkdir -p "$BUILD"

echo "Archiving build $BUILD_NUMBER…"
xcodebuild -project JPlus.xcodeproj -scheme JPlus -configuration Release \
    -destination "generic/platform=iOS" -archivePath "$ARCHIVE" \
    DEVELOPMENT_TEAM="$TEAM" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    -allowProvisioningUpdates archive -quiet

VERSION=$(/usr/libexec/PlistBuddy -c "Print ApplicationProperties:CFBundleShortVersionString" "$ARCHIVE/Info.plist")

if [[ "${1:-}" == "--export-only" ]]; then
    echo "Exporting JPlus $VERSION ($BUILD_NUMBER) for the App Store…"
else
    echo "Uploading JPlus $VERSION ($BUILD_NUMBER) to App Store Connect…"
fi
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$OPTIONS" -exportPath "$EXPORT" -allowProvisioningUpdates -quiet

if [[ "${1:-}" == "--export-only" ]]; then
    echo "Done: $EXPORT/JPlus.ipa"
else
    echo "Done. JPlus $VERSION ($BUILD_NUMBER) appears in App Store Connect › TestFlight once Apple finishes processing it."
fi

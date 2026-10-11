#!/bin/zsh
# Builds a Release archive of JPlus, exports it signed with Developer ID,
# notarizes it with Apple and staples the ticket. The result is
# build/JPlus.app and build/JPlus-<version>.zip, ready to share.
#
# Releases are signed by team 89V5HKLEV9 (sichengxu@gmail.com); the
# project's own Debug signing stays on the development team.
#
# One-time setup:
#   1. A "Developer ID Application" certificate for team 89V5HKLEV9 in your
#      login keychain. Xcode creates one during the export below if the Apple
#      ID signed into Xcode is the team's Account Holder; otherwise make it in
#      Xcode › Settings › Accounts › Manage Certificates › +.
#   2. Notary credentials saved under a keychain profile:
#        xcrun notarytool store-credentials "jplus-notary" \
#          --apple-id sichengxu@gmail.com --team-id 89V5HKLEV9
#      (asks for an app-specific password from appleid.apple.com), or
#      --key /path/AuthKey.p8 --key-id KEYID --issuer ISSUER for an App Store
#      Connect API key.
#
# Usage: scripts/notarize.sh [keychain-profile]   (default: jplus-notary)
set -euo pipefail

cd "$(dirname "$0")/.."
PROFILE="${1:-jplus-notary}"
TEAM=89V5HKLEV9
BUILD=build
ARCHIVE="$BUILD/JPlus.xcarchive"
EXPORT="$BUILD/export"

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    echo "No Developer ID Application certificate in the keychain yet; asking Xcode to create one for team $TEAM."
fi

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    cat >&2 <<MSG
No notary credentials stored under the keychain profile "$PROFILE". Store them once with
  xcrun notarytool store-credentials "$PROFILE" --apple-id sichengxu@gmail.com --team-id $TEAM
(it asks for an app-specific password from account.apple.com), then run this script again.
MSG
    exit 1
fi

rm -rf "$ARCHIVE" "$EXPORT"
mkdir -p "$BUILD"

echo "Archiving…"
xcodebuild -project JPlus.xcodeproj -scheme JPlus -configuration Release \
    -archivePath "$ARCHIVE" DEVELOPMENT_TEAM="$TEAM" -allowProvisioningUpdates archive -quiet

echo "Exporting with Developer ID…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist scripts/ExportOptions.plist -exportPath "$EXPORT" -allowProvisioningUpdates -quiet

APP="$EXPORT/JPlus.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
ZIP="$BUILD/JPlus-$VERSION.zip"

echo "Checking the signature…"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "Submitting to Apple for notarization…"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "Stapling…"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

# Re-zip with the stapled ticket inside.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
rm -rf "$BUILD/JPlus.app"
mv "$APP" "$BUILD/JPlus.app"
echo "Done: $BUILD/JPlus.app and $ZIP"

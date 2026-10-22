#!/bin/zsh
# Makes a notarized disk image of JPlus and publishes it as a GitHub release
# on the public sichx/jplus-releases repository, then tags this repository.
# Each release also carries appcast.xml, the feed the app's Sparkle updater
# reads, with the image signed by the Sparkle key in your keychain (made with
# `generate_keys --account jplus`; its public half is SUPublicEDKey in
# JPlus/Info-macOS.plist).
#
# Usage: scripts/release.sh [--reuse-app]
#   --reuse-app  skip scripts/notarize.sh and use the stapled build/JPlus.app
#                from an earlier run.
#
# The version is the project's Marketing Version; bump it in Xcode before a
# release. Each release uploads JPlus-<version>.dmg plus a copy named
# JPlus.dmg, so https://github.com/sichx/jplus-releases/releases/latest/download/JPlus.dmg
# always fetches the newest build, and .../releases/latest/download/appcast.xml
# always describes it.
set -euo pipefail

cd "$(dirname "$0")/.."
PROFILE=jplus-notary
RELEASES_REPO=github.com/sichx/jplus-releases
BUILD=build
APP=$BUILD/JPlus.app
SPARKLE_KEY_ACCOUNT=jplus
SPARKLE_BIN=$BUILD/SourcePackages/artifacts/sparkle/Sparkle/bin

echo "Fetching Sparkle's tools…"
xcodebuild -resolvePackageDependencies -project JPlus.xcodeproj -scheme JPlus \
    -clonedSourcePackagesDirPath "$BUILD/SourcePackages" -quiet
PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c "Print SUPublicEDKey" JPlus/Info-macOS.plist)
if [[ "$("$SPARKLE_BIN/generate_keys" --account "$SPARKLE_KEY_ACCOUNT" -p 2>/dev/null)" != "$PUBLIC_KEY" ]]; then
    echo "The keychain's Sparkle key ($SPARKLE_KEY_ACCOUNT) doesn't match SUPublicEDKey in JPlus/Info-macOS.plist, so installed copies would reject the update." >&2
    exit 1
fi

if [[ "${1:-}" == "--reuse-app" ]]; then
    [[ -d "$APP" ]] || { echo "No $APP to reuse; run without --reuse-app." >&2; exit 1; }
else
    scripts/notarize.sh "$PROFILE"
fi
xcrun stapler validate "$APP" >/dev/null || { echo "$APP is not notarized." >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist")
MINIMUM_OS=$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" "$APP/Contents/Info.plist")
TAG="v$VERSION"
DMG="$BUILD/JPlus-$VERSION.dmg"
LATEST="$BUILD/JPlus.dmg"
APPCAST="$BUILD/appcast.xml"

if gh release view "$TAG" --repo "$RELEASES_REPO" >/dev/null 2>&1; then
    echo "Release $TAG already exists on $RELEASES_REPO; bump the Marketing Version first." >&2
    exit 1
fi

echo "Building $DMG…"
STAGING="$BUILD/dmg-staging"
rm -rf "$STAGING" "$DMG" "$LATEST"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "JPlus $VERSION" -srcfolder "$STAGING" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGING"

# Xcode's cloud-managed Developer ID certificate isn't visible to codesign,
# so the image is signed only when a conventional one is in the keychain.
# Notarization accepts an unsigned image as long as the app inside is signed.
if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    echo "Signing the image…"
    codesign --sign "Developer ID Application" --timestamp "$DMG"
fi

echo "Submitting the image to Apple for notarization…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
cp "$DMG" "$LATEST"

echo "Writing release notes…"
# The previous release is the newest tag by version, not the nearest one, and
# --cherry-pick drops commits it already shipped: a rebase after a release
# leaves its tag off this branch, with its commits here under new hashes.
PREVIOUS=$(git tag --list 'v*' --sort=-version:refname | head -1)
if [[ -n "$PREVIOUS" ]]; then
    CHANGES=$(printf 'Changes since %s:\n\n' "$PREVIOUS"; git log --no-merges --right-only --cherry-pick --invert-grep --grep='^Bump the version' --pretty='- %s' "$PREVIOUS...HEAD")
else
    CHANGES="First release."
fi
NOTES=$(printf '%s\n\nDownload JPlus.dmg, open it and drag JPlus to Applications. Requires macOS 15 or later. Signed with Developer ID and notarized by Apple.' "$CHANGES")

# Sparkle compares sparkle:version with the installed app's CFBundleVersion,
# which on the Mac is the version itself.
echo "Signing the update and writing $APPCAST…"
SIGNATURE=$("$SPARKLE_BIN/sign_update" --account "$SPARKLE_KEY_ACCOUNT" "$DMG")
cat >"$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>JPlus</title>
    <item>
      <title>JPlus $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINIMUM_OS</sparkle:minimumSystemVersion>
      <description sparkle:format="markdown"><![CDATA[$CHANGES]]></description>
      <enclosure url="https://github.com/sichx/jplus-releases/releases/download/$TAG/JPlus-$VERSION.dmg" type="application/octet-stream" $SIGNATURE/>
    </item>
  </channel>
</rss>
XML

echo "Publishing $TAG to $RELEASES_REPO…"
gh release create "$TAG" --repo "$RELEASES_REPO" --title "JPlus $VERSION" --notes "$NOTES" "$DMG" "$LATEST" "$APPCAST"

echo "Tagging the source as $TAG…"
git tag -a "$TAG" -m "JPlus $VERSION"
git push origin "$TAG"
echo "Done: https://github.com/sichx/jplus-releases/releases/tag/$TAG"

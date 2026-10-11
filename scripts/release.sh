#!/bin/zsh
# Makes a notarized disk image of JPlus and publishes it as a GitHub release
# on the public sichx/jplus-releases repository, then tags this repository.
#
# Usage: scripts/release.sh [--reuse-app]
#   --reuse-app  skip scripts/notarize.sh and use the stapled build/JPlus.app
#                from an earlier run.
#
# The version is the project's Marketing Version; bump it in Xcode before a
# release. Each release uploads JPlus-<version>.dmg plus a copy named
# JPlus.dmg, so https://github.com/sichx/jplus-releases/releases/latest/download/JPlus.dmg
# always fetches the newest build.
set -euo pipefail

cd "$(dirname "$0")/.."
PROFILE=jplus-notary
RELEASES_REPO=github.com/sichx/jplus-releases
BUILD=build
APP=$BUILD/JPlus.app

if [[ "${1:-}" == "--reuse-app" ]]; then
    [[ -d "$APP" ]] || { echo "No $APP to reuse; run without --reuse-app." >&2; exit 1; }
else
    scripts/notarize.sh "$PROFILE"
fi
xcrun stapler validate "$APP" >/dev/null || { echo "$APP is not notarized." >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
TAG="v$VERSION"
DMG="$BUILD/JPlus-$VERSION.dmg"
LATEST="$BUILD/JPlus.dmg"

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
PREVIOUS=$(git describe --tags --abbrev=0 2>/dev/null || true)
if [[ -n "$PREVIOUS" ]]; then
    NOTES=$(printf 'Changes since %s:\n\n' "$PREVIOUS"; git log --no-merges --pretty='- %s' "$PREVIOUS..HEAD")
else
    NOTES="First release."
fi
NOTES=$(printf '%s\n\nDownload JPlus.dmg, open it and drag JPlus to Applications. Requires macOS 15 or later. Signed with Developer ID and notarized by Apple.' "$NOTES")

echo "Publishing $TAG to $RELEASES_REPO…"
gh release create "$TAG" --repo "$RELEASES_REPO" --title "JPlus $VERSION" --notes "$NOTES" "$DMG" "$LATEST"

echo "Tagging the source as $TAG…"
git tag -a "$TAG" -m "JPlus $VERSION"
git push origin "$TAG"
echo "Done: https://github.com/sichx/jplus-releases/releases/tag/$TAG"

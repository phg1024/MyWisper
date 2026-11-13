#!/bin/bash
# Builds a release DMG for GitHub.   ./release.sh 1.0.0
#
# With a "Developer ID Application" certificate in the login keychain (Apple Developer Program),
# the app and DMG are signed with it, notarized and stapled, so they open without any warning.
# That also needs notarization credentials saved once:
#   xcrun notarytool store-credentials mywisper-notary --apple-id <Apple ID> --team-id <TEAMID>
#
# Without one, the app is signed with the project's self-signed certificate (.signing/) and the DMG
# isn't notarized: people have to allow it once under System Settings › Privacy & Security
# ("Open Anyway"). Keep .signing/ (and a backup): later releases signed with the same certificate
# keep the Microphone and Accessibility permissions people already granted.
#
# It doesn't publish anything; it prints the `gh release` command at the end.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=${1:?usage: ./release.sh <version>, e.g. 1.0.0}
NOTARY_PROFILE=${NOTARY_PROFILE:-mywisper-notary}
DEVELOPER_ID=${DEVELOPER_ID:-$(security find-identity -v -p codesigning \
  | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "commit your changes first"; exit 1; }
if [ -n "$DEVELOPER_ID" ]; then echo "signing as: $DEVELOPER_ID (will notarize)"; else echo "no Developer ID: self-signed, not notarized"; fi

DEVELOPER_ID="$DEVELOPER_ID" VERSION="$VERSION" ./build.sh
APP=build/MyWisper.app
codesign --verify --deep --strict "$APP"
! grep -rqaF "$HOME" "$APP/Contents/MacOS" "$APP/Contents/Frameworks" \
  || { echo "the app contains this Mac's home path ($HOME); rerun ./fetch-deps.sh"; exit 1; }

if [ -n "$DEVELOPER_ID" ]; then
  # Notarize the app itself and staple the ticket, so it opens even offline once copied out of the DMG.
  ditto -c -k --keepParent "$APP" build/MyWisper-notarize.zip
  xcrun notarytool submit build/MyWisper-notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f build/MyWisper-notarize.zip
fi

# DMG with the app and an Applications shortcut.
DMG=build/MyWisper-$VERSION.dmg
rm -rf build/dmg "$DMG"
mkdir -p build/dmg
ditto "$APP" build/dmg/MyWisper.app
ln -s /Applications build/dmg/Applications
hdiutil create -volname "MyWisper $VERSION" -srcfolder build/dmg -fs HFS+ -format UDZO -o "$DMG" >/dev/null
rm -rf build/dmg

if [ -n "$DEVELOPER_ID" ]; then
  codesign --sign "$DEVELOPER_ID" --timestamp "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  # Check it the way Gatekeeper will on someone else's Mac.
  spctl --assess --type execute --verbose=2 "$APP"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
  xcrun stapler validate "$DMG"
fi
hdiutil verify "$DMG" >/dev/null

SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
echo
echo "ready: $DMG ($(du -h "$DMG" | cut -f1), sha256 $SHA)"
echo "publish with:"
echo "  git tag v$VERSION && git push origin v$VERSION"
echo "  gh release create v$VERSION '$DMG' --title 'MyWisper $VERSION' --notes-file <notes.md>"

#!/bin/bash
# Builds a release for GitHub: Developer ID signature, notarized and stapled app inside a notarized DMG.
#   ./release.sh 1.0.0
# Needs, once:
#   - a "Developer ID Application" certificate in the login keychain (Xcode › Settings › Accounts, or
#     developer.apple.com › Certificates);
#   - notarization credentials saved in the keychain under the profile name below:
#       xcrun notarytool store-credentials mywisper-notary --apple-id <Apple ID> --team-id <TEAMID>
#     (it asks for an app-specific password from account.apple.com).
# It doesn't publish anything; it prints the `gh release` command at the end.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=${1:?usage: ./release.sh <version>, e.g. 1.0.0}
NOTARY_PROFILE=${NOTARY_PROFILE:-mywisper-notary}
DEVELOPER_ID=${DEVELOPER_ID:-$(security find-identity -v -p codesigning \
  | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}
[ -n "$DEVELOPER_ID" ] || { echo "no Developer ID Application certificate in the keychain"; exit 1; }
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "commit your changes first"; exit 1; }
echo "signing as: $DEVELOPER_ID"

DEVELOPER_ID="$DEVELOPER_ID" VERSION="$VERSION" ./build.sh
APP=build/MyWisper.app
codesign --verify --deep --strict "$APP"

# 1. Notarize the app itself and staple the ticket, so it opens even offline after it's copied out of the DMG.
ditto -c -k --keepParent "$APP" build/MyWisper-notarize.zip
xcrun notarytool submit build/MyWisper-notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm -f build/MyWisper-notarize.zip

# 2. DMG with the app and an Applications shortcut, signed, notarized and stapled too.
DMG=build/MyWisper-$VERSION.dmg
rm -rf build/dmg "$DMG"
mkdir -p build/dmg
ditto "$APP" build/dmg/MyWisper.app
ln -s /Applications build/dmg/Applications
hdiutil create -volname "MyWisper $VERSION" -srcfolder build/dmg -fs HFS+ -format UDZO -o "$DMG" >/dev/null
rm -rf build/dmg
codesign --sign "$DEVELOPER_ID" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

# 3. Check it the way Gatekeeper will on someone else's Mac.
spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
xcrun stapler validate "$DMG"

SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
echo
echo "ready: $DMG ($(du -h "$DMG" | cut -f1), sha256 $SHA)"
echo "publish with:"
echo "  git tag v$VERSION && git push origin v$VERSION"
echo "  gh release create v$VERSION '$DMG' --title 'MyWisper $VERSION' --notes-file <notes.md>"

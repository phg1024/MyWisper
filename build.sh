#!/bin/bash
# Builds MyWisper.app (release) into build/. `./build.sh install` also copies it to ~/Applications.
# Needs Xcode (or the command line tools), plus sherpa-onnx's C library in Vendor/ and the SenseVoice
# model in models/: ./fetch-deps.sh downloads both.
set -euo pipefail
cd "$(dirname "$0")"

MODEL=models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17
[ -f Vendor/sherpa-onnx/lib/libsherpa-onnx-c-api.dylib ] && [ -f Vendor/sherpa-onnx/include/sherpa-onnx/c-api/c-api.h ] \
  || { echo "missing Vendor/sherpa-onnx: run ./fetch-deps.sh"; exit 1; }
[ -f "$MODEL/model.int8.onnx" ] || { echo "missing $MODEL/model.int8.onnx: run ./fetch-deps.sh"; exit 1; }

swift build -c release
BIN="$(swift build -c release --show-bin-path)/MyWisper"

APP=build/MyWisper.app
STAGE=build/.stage/MyWisper.app
rm -rf build/.stage
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Frameworks" "$STAGE/Contents/Resources/model"
cp "$BIN" "$STAGE/Contents/MacOS/MyWisper"
cp Vendor/sherpa-onnx/lib/*.dylib "$STAGE/Contents/Frameworks/"
cp Resources/Info.plist "$STAGE/Contents/Info.plist"
cp -c "$MODEL/model.int8.onnx" "$MODEL/tokens.txt" "$STAGE/Contents/Resources/model/" 2>/dev/null \
  || cp "$MODEL/model.int8.onnx" "$MODEL/tokens.txt" "$STAGE/Contents/Resources/model/"   # -c: APFS clone, instant
cp "$MODEL/LICENSE" "$STAGE/Contents/Resources/model/" 2>/dev/null || true

"$STAGE/Contents/MacOS/MyWisper" --make-icon build/.stage/AppIcon.iconset
iconutil -c icns build/.stage/AppIcon.iconset -o "$STAGE/Contents/Resources/AppIcon.icns"

# Signed with a self-signed certificate kept in .signing/ (made on the first build, not in git).
# macOS ties privacy permissions to the signature's certificate, so with a stable certificate
# Microphone and Accessibility survive rebuilds; an ad-hoc signature would change every build.
SIGN_DIR="$PWD/.signing"
KC="$SIGN_DIR/signing.keychain-db"
IDENTITY="MyWisper Local Signing"
if [ ! -f "$KC" ]; then
  mkdir -p "$SIGN_DIR" && chmod 700 "$SIGN_DIR"
  (
    cd "$SIGN_DIR"
    umask 077
    openssl rand -hex 16 > password
    printf '[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=%s\n[ext]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' "$IDENTITY" > cert.cnf
    openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 7300 -config cert.cnf 2>/dev/null
    openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -out identity.p12 -passout file:password
    security create-keychain -p "$(cat password)" "$KC"
    security unlock-keychain -p "$(cat password)" "$KC"
    security import identity.p12 -k "$KC" -P "$(cat password)" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple: -s -k "$(cat password)" "$KC" >/dev/null
  )
  echo "created signing certificate in $SIGN_DIR"
fi
security unlock-keychain -p "$(cat "$SIGN_DIR/password")" "$KC"
codesign --force --keychain "$KC" --sign "$IDENTITY" "$STAGE/Contents/Frameworks/"*.dylib
codesign --force --keychain "$KC" --sign "$IDENTITY" --identifier com.peihongguo.MyWisper "$STAGE"

rm -rf "$APP"
mv "$STAGE" "$APP"
rm -rf build/.stage
echo "built $APP ($(du -sh "$APP" | cut -f1))"

if [ "${1:-}" = "install" ]; then
  pkill -x MyWisper 2>/dev/null && sleep 1 || true
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/MyWisper.app"
  cp -R "$APP" "$HOME/Applications/"
  echo "installed ~/Applications/MyWisper.app"
fi

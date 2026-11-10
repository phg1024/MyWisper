#!/bin/bash
# Builds MyWisper.app (release) into build/. `./build.sh install` also copies it to ~/Applications.
# Needs Xcode (or the command line tools) and the Python app's venv and model next door, which supply
# sherpa-onnx's C library and the SenseVoice model.
set -euo pipefail
cd "$(dirname "$0")"

WHEEL=../venv/lib/python3.9/site-packages/sherpa_onnx
MODEL=../models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17
[ -f "$WHEEL/lib/libsherpa-onnx-c-api.dylib" ] || { echo "missing $WHEEL (run ../run.sh once to create the venv)"; exit 1; }
[ -f "$MODEL/model.int8.onnx" ] || { echo "missing $MODEL/model.int8.onnx"; exit 1; }

mkdir -p Vendor/sherpa-onnx/lib Vendor/sherpa-onnx/include
cp -p "$WHEEL/lib/libsherpa-onnx-c-api.dylib" "$WHEEL/lib/libonnxruntime.dylib" Vendor/sherpa-onnx/lib/
cp -Rp "$WHEEL/include/sherpa-onnx" Vendor/sherpa-onnx/include/

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

# Ad-hoc signature (no developer certificate on this Mac). macOS ties privacy permissions to it,
# so after a rebuild Accessibility has to be granted again.
codesign --force --sign - "$STAGE/Contents/Frameworks/"*.dylib
codesign --force --sign - --identifier com.peihongguo.MyWisper "$STAGE"

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

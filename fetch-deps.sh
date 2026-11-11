#!/bin/bash
# Downloads what build.sh needs but git doesn't keep, from sherpa-onnx's GitHub releases:
#   Vendor/sherpa-onnx/  the C API and onnxruntime dylibs (arm64) and the C header
#   models/...           the SenseVoice model (a ~1 GB download; only model.int8.onnx goes into the app)
set -euo pipefail
cd "$(dirname "$0")"

SHERPA_VERSION=2.0.1
MODEL_NAME=sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17
RELEASES=https://github.com/k2-fsa/sherpa-onnx/releases/download

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [ ! -f Vendor/sherpa-onnx/lib/libsherpa-onnx-c-api.dylib ]; then
  name=sherpa-onnx-v$SHERPA_VERSION-osx-arm64-shared-no-tts-lib
  echo "downloading $name"
  curl -fL --progress-bar "$RELEASES/v$SHERPA_VERSION/$name.tar.bz2" | tar xj -C "$TMP"
  mkdir -p Vendor/sherpa-onnx/lib Vendor/sherpa-onnx/include
  find "$TMP" -name '*.dylib' -exec cp -P {} Vendor/sherpa-onnx/lib/ \;
  header=$(find "$TMP" -path '*sherpa-onnx/c-api/c-api.h' | head -1)
  [ -n "$header" ] || { echo "no c-api.h in $name"; exit 1; }
  cp -R "$(dirname "$(dirname "$header")")" Vendor/sherpa-onnx/include/
  [ -f Vendor/sherpa-onnx/lib/libsherpa-onnx-c-api.dylib ] || { echo "no libsherpa-onnx-c-api.dylib in $name"; exit 1; }
fi

if [ ! -f "models/$MODEL_NAME/model.int8.onnx" ]; then
  echo "downloading $MODEL_NAME"
  mkdir -p models
  curl -fL --progress-bar "$RELEASES/asr-models/$MODEL_NAME.tar.bz2" | tar xj -C models
fi
echo "dependencies ready"

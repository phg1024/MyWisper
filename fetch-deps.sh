#!/bin/bash
# Downloads what build.sh needs but git doesn't keep, from sherpa-onnx's GitHub releases:
#   Vendor/sherpa-onnx/  the C API and onnxruntime dylibs (arm64) and the C header
#   models/...           the SenseVoice model (a ~1 GB download; only model.int8.onnx goes into the app)
# and whisper.cpp: the source from GitHub, built here into static libraries with Metal (Vendor/whisper/),
# and its large-v3-turbo q8_0 model from Hugging Face (models/whisper/, 874 MB).
set -euo pipefail
cd "$(dirname "$0")"

SHERPA_VERSION=2.0.1
MODEL_NAME=sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17
RELEASES=https://github.com/k2-fsa/sherpa-onnx/releases/download
WHISPER_VERSION=v1.9.5
WHISPER_MODEL=ggml-large-v3-turbo-q8_0.bin

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
if [ ! -f Vendor/whisper/lib/libwhisper.a ]; then
  [ -d Vendor/whisper.cpp-src ] || git clone --depth 1 --branch "$WHISPER_VERSION" https://github.com/ggml-org/whisper.cpp Vendor/whisper.cpp-src
  # GGML_NATIVE=OFF: runs on every Apple silicon Mac, not only the one that built it.
  cmake -S Vendor/whisper.cpp-src -B Vendor/whisper.cpp-src/build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF -DCMAKE_INSTALL_PREFIX="$PWD/Vendor/whisper"
  cmake --build Vendor/whisper.cpp-src/build -j "$(sysctl -n hw.ncpu)" --config Release
  cmake --install Vendor/whisper.cpp-src/build
fi

if [ ! -f "models/whisper/$WHISPER_MODEL" ]; then
  echo "downloading $WHISPER_MODEL"
  mkdir -p models/whisper
  curl -fL --progress-bar -o "models/whisper/$WHISPER_MODEL.part" "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$WHISPER_MODEL"
  mv "models/whisper/$WHISPER_MODEL.part" "models/whisper/$WHISPER_MODEL"
fi
echo "dependencies ready"

#!/bin/bash
# Downloads what build.sh needs but git doesn't keep, from sherpa-onnx's GitHub releases:
#   Vendor/sherpa-onnx/  the C API and onnxruntime dylibs (arm64) and the C header
#   models/...           the SenseVoice model (a ~1 GB download; only model.int8.onnx goes into the app)
# and llama.cpp for correction: the source from GitHub, built here into static libraries with Metal
# (Vendor/llama/). The correction model itself isn't bundled; the app downloads it when the user asks.
set -euo pipefail
cd "$(dirname "$0")"

SHERPA_VERSION=2.0.1
MODEL_NAME=sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17
RELEASES=https://github.com/k2-fsa/sherpa-onnx/releases/download
LLAMA_VERSION=v0.9.0

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
# Bump LLAMA_BUILD when the build flags change, so existing checkouts rebuild.
LLAMA_BUILD="$LLAMA_VERSION-2"
if [ ! -f Vendor/llama/lib/libllama.a ] || [ "$(cat Vendor/llama/BUILD 2>/dev/null)" != "$LLAMA_BUILD" ]; then
  [ -d Vendor/llama.cpp-src ] || git clone --depth 1 --branch "$LLAMA_VERSION" https://github.com/ggml-org/llama.cpp Vendor/llama.cpp-src
  # GGML_NATIVE=OFF: runs on every Apple silicon Mac, not only the one that built it.
  # -ffile-prefix-map: llama.cpp's assert messages embed source paths; keep this Mac's home path out.
  PREFIX_MAP="-ffile-prefix-map=$PWD/Vendor/llama.cpp-src=llama.cpp"
  cmake -S Vendor/llama.cpp-src -B Vendor/llama.cpp-src/build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DCMAKE_C_FLAGS="$PREFIX_MAP" -DCMAKE_CXX_FLAGS="$PREFIX_MAP" -DCMAKE_OBJC_FLAGS="$PREFIX_MAP" -DCMAKE_ASM_FLAGS="$PREFIX_MAP" \
    -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_APP=OFF -DCMAKE_INSTALL_PREFIX="$PWD/Vendor/llama"
  cmake --build Vendor/llama.cpp-src/build -j "$(sysctl -n hw.ncpu)" --config Release
  cmake --install Vendor/llama.cpp-src/build
  echo "$LLAMA_BUILD" > Vendor/llama/BUILD
fi
echo "dependencies ready"

#!/bin/sh
# Build the distributable executable and its matching MLX Metal library.
set -eu
cd "$(dirname "$0")/.."
xcodebuild build -scheme parrot -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath .xcbuild \
    -onlyUsePackageVersionsFromResolvedFile -quiet
PRODUCTS=.xcbuild/Build/Products/Release
SHADERS="$PRODUCTS/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
if [ ! -s "$SHADERS" ]; then
    echo 'MLX shaders were not built. Install the Xcode Metal toolchain and retry.' >&2
    exit 1
fi
mkdir -p dist
cp "$PRODUCTS/parrot" dist/parrot
cp "$SHADERS" dist/mlx.metallib
# A source-only build may work for dictation but cannot run the translation GPU.
# Keep these two files together, including when testing without installing.
printf 'Built dist/parrot and dist/mlx.metallib\n'

#!/usr/bin/env bash
#
# build_buildroot_enclave.sh
#
# Build the muinference Weight Enclave using Buildroot.
# This creates a minimal Linux VM image for SL5-style GPU inference.
#
# Caching:
#   - Buildroot source is cached in $BUILDROOT_CACHE_DIR/buildroot
#   - Download cache is in $BUILDROOT_CACHE_DIR/dl
#   - Build artifacts are in $BUILDROOT_CACHE_DIR/output
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Use cache directory if set (Docker), otherwise use local
CACHE_DIR="${BUILDROOT_CACHE_DIR:-$ROOT}"
BR_DIR="$CACHE_DIR/buildroot"
BR_VERSION="${BR_VERSION:-2024.02.1}"

echo "=== muinference Buildroot Enclave Builder ==="
echo "Root directory: $ROOT"
echo "Cache directory: $CACHE_DIR"
echo "Buildroot directory: $BR_DIR"
echo ""

# Clone Buildroot if not present or incomplete
if [ ! -d "$BR_DIR/configs" ]; then
    echo ">>> Cloning Buildroot ${BR_VERSION}..."
    rm -rf "$BR_DIR" 2>/dev/null || true
    git clone --depth 1 --branch "${BR_VERSION}" \
        https://git.buildroot.net/buildroot "$BR_DIR"
else
    echo ">>> Using cached Buildroot at $BR_DIR"
fi

# Copy our defconfig to Buildroot configs directory
echo ">>> Installing muinference defconfig..."
cp "$ROOT/external/muinference/muinference_defconfig" "$BR_DIR/configs/muinference_defconfig"

cd "$BR_DIR"

# Set up external tree
export BR2_EXTERNAL="$ROOT/external/muinference"

# Use cached download directory
export BR2_DL_DIR="$CACHE_DIR/dl"
mkdir -p "$BR2_DL_DIR"

echo ">>> Configuring Buildroot with muinference_defconfig..."
make muinference_defconfig

echo ">>> Building (this may take 30-60 minutes on first run)..."
echo ">>> Subsequent builds will be faster due to caching."
NPROC=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
make -j"$NPROC"

# Copy output to the mounted output directory
echo ">>> Copying build artifacts..."
mkdir -p "$ROOT/output/images"
cp -r "$BR_DIR/output/images/"* "$ROOT/output/images/" 2>/dev/null || true

echo ""
echo "=== Build Complete ==="
echo ""
echo "Output images:"
ls -lh "$ROOT/output/images/" 2>/dev/null || ls -lh "$BR_DIR/output/images/"
echo ""
echo "To run the enclave VM:"
echo "  docker compose -f docker-compose.build.yml run enclave"
echo ""

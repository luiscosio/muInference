#!/usr/bin/env bash
#
# build_buildroot_enclave.sh
#
# Build the muinference Weight Enclave using Buildroot.
# This creates a minimal Linux VM image for SL5-style GPU inference.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BR_DIR="$ROOT/buildroot"
BR_VERSION="${BR_VERSION:-2024.02.1}"

echo "=== muinference Buildroot Enclave Builder ==="
echo "Root directory: $ROOT"
echo "Buildroot directory: $BR_DIR"
echo ""

# Clone Buildroot if not present
if [ ! -d "$BR_DIR" ]; then
    echo ">>> Cloning Buildroot ${BR_VERSION}..."
    git clone --depth 1 --branch "${BR_VERSION}" \
        https://git.buildroot.net/buildroot "$BR_DIR"
else
    echo ">>> Buildroot already present at $BR_DIR"
fi

# Copy our defconfig to Buildroot configs directory
echo ">>> Installing muinference defconfig..."
cp "$ROOT/external/muinference/muinference_defconfig" "$BR_DIR/configs/muinference_defconfig"

cd "$BR_DIR"

# Set up external tree
export BR2_EXTERNAL="$ROOT/external/muinference"

echo ">>> Configuring Buildroot with muinference_defconfig..."
make muinference_defconfig

echo ">>> Building (this may take 30-60 minutes on first run)..."
NPROC=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
make -j"$NPROC"

echo ""
echo "=== Build Complete ==="
echo ""
echo "Output images:"
ls -lh "$BR_DIR/output/images/"
echo ""
echo "To run the enclave VM:"
echo "  ./scripts/run_enclave_vm.sh"
echo ""

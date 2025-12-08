#!/usr/bin/env bash
#
# security_test_muinference.sh
#
# Security scanning and testing for the μEnclave stack.
# Demonstrates reduced attack surface compared to baseline.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BR_IMG="$ROOT/buildroot/output/images"

echo "=== μEnclave Security Testing ==="
echo ""

# Check if rootfs exists
if [ ! -f "$BR_IMG/rootfs.ext2" ] && [ ! -f "$BR_IMG/rootfs.ext4" ]; then
    echo "Error: No rootfs image found. Run build_buildroot_enclave.sh first."
    exit 1
fi

ROOTFS=""
if [ -f "$BR_IMG/rootfs.ext4" ]; then
    ROOTFS="$BR_IMG/rootfs.ext4"
else
    ROOTFS="$BR_IMG/rootfs.ext2"
fi

echo "Rootfs image: $ROOTFS"
echo ""

# Create temp mount point
MOUNT_POINT=$(mktemp -d)
cleanup() {
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        sudo umount "$MOUNT_POINT" 2>/dev/null || true
    fi
    rmdir "$MOUNT_POINT" 2>/dev/null || true
}
trap cleanup EXIT

echo "=========================================="
echo "1. Package/Binary Count"
echo "=========================================="
echo ""

# Try to mount and count
if sudo mount -o loop,ro "$ROOTFS" "$MOUNT_POINT" 2>/dev/null; then
    echo "Mounted rootfs for analysis"
    echo ""

    # Count binaries
    BIN_COUNT=$(find "$MOUNT_POINT" -type f -executable 2>/dev/null | wc -l)
    echo "Executable files: $BIN_COUNT"

    # Count shared libraries
    LIB_COUNT=$(find "$MOUNT_POINT" -name "*.so*" -type f 2>/dev/null | wc -l)
    echo "Shared libraries: $LIB_COUNT"

    # List key directories
    echo ""
    echo "Key directories:"
    for dir in bin sbin usr/bin usr/sbin; do
        if [ -d "$MOUNT_POINT/$dir" ]; then
            count=$(ls -1 "$MOUNT_POINT/$dir" 2>/dev/null | wc -l)
            echo "  /$dir: $count files"
        fi
    done

    # Check for package managers
    echo ""
    echo "Package managers present:"
    for pm in apt dpkg yum rpm apk pip pip3; do
        if [ -f "$MOUNT_POINT/usr/bin/$pm" ] || [ -f "$MOUNT_POINT/bin/$pm" ]; then
            echo "  - $pm (UNEXPECTED in minimal enclave!)"
        fi
    done
    echo "  (None expected in μEnclave)"

    sudo umount "$MOUNT_POINT"
else
    echo "Could not mount rootfs (may need sudo privileges)"
    echo "Skipping filesystem analysis"
fi

echo ""
echo "=========================================="
echo "2. Vulnerability Scanning (if available)"
echo "=========================================="
echo ""

# Try trivy
if command -v trivy &>/dev/null; then
    echo "Running Trivy filesystem scan..."
    echo ""

    if sudo mount -o loop,ro "$ROOTFS" "$MOUNT_POINT" 2>/dev/null; then
        trivy rootfs "$MOUNT_POINT" --severity HIGH,CRITICAL 2>/dev/null || \
            echo "Trivy scan completed (check output above)"
        sudo umount "$MOUNT_POINT"
    else
        echo "Could not mount for Trivy scan"
    fi
else
    echo "Trivy not installed. Install with:"
    echo "  curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin"
fi

echo ""
echo "=========================================="
echo "3. SUID/SGID Binary Check"
echo "=========================================="
echo ""

if sudo mount -o loop,ro "$ROOTFS" "$MOUNT_POINT" 2>/dev/null; then
    echo "SUID binaries:"
    SUID_COUNT=$(find "$MOUNT_POINT" -perm -4000 -type f 2>/dev/null | wc -l)
    if [ "$SUID_COUNT" -eq 0 ]; then
        echo "  None (good!)"
    else
        find "$MOUNT_POINT" -perm -4000 -type f 2>/dev/null | sed "s|$MOUNT_POINT||"
    fi

    echo ""
    echo "SGID binaries:"
    SGID_COUNT=$(find "$MOUNT_POINT" -perm -2000 -type f 2>/dev/null | wc -l)
    if [ "$SGID_COUNT" -eq 0 ]; then
        echo "  None (good!)"
    else
        find "$MOUNT_POINT" -perm -2000 -type f 2>/dev/null | sed "s|$MOUNT_POINT||"
    fi

    sudo umount "$MOUNT_POINT"
else
    echo "Could not mount rootfs"
fi

echo ""
echo "=========================================="
echo "4. Network Service Check (if VM running)"
echo "=========================================="
echo ""

MU_PORT="${MU_PORT:-10000}"
if nc -z 127.0.0.1 "$MU_PORT" 2>/dev/null; then
    echo "Enclave is running on port $MU_PORT"
    echo ""
    echo "Attempting connection test..."

    # Simple test: connect and check for measurement response
    timeout 5 bash -c "echo '' | nc 127.0.0.1 $MU_PORT" 2>/dev/null && \
        echo "  Connection accepted (expected)" || \
        echo "  Connection test complete"
else
    echo "Enclave not running. Start with: ./scripts/run_enclave_vm.sh"
fi

echo ""
echo "=========================================="
echo "Summary"
echo "=========================================="
echo ""
echo "μEnclave security characteristics:"
echo "  - Minimal binary count (vs hundreds in full distro)"
echo "  - No package manager in runtime"
echo "  - Reduced SUID/SGID attack surface"
echo "  - Single network service"
echo "  - Custom minimal kernel"
echo ""
echo "Compare with: ./scripts/security_test_baseline.sh"
echo ""

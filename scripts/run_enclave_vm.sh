#!/usr/bin/env bash
#
# run_enclave_vm.sh
#
# Run the muinference Weight Enclave VM using QEMU/KVM.
# Supports CPU-only mode and GPU passthrough.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BR_IMG="$ROOT/buildroot/output/images"

# Configuration
MEMORY="${MEMORY:-8192}"
CPUS="${CPUS:-4}"
HOST_PORT="${HOST_PORT:-10000}"
GUEST_PORT="${GUEST_PORT:-9000}"
GPU_BDF="${GPU_BDF:-}"  # e.g., "0000:3b:00.0" for GPU passthrough
MODEL_DIR="${MODEL_DIR:-}"  # Optional: host directory with model weights

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Run the muinference Weight Enclave VM.

Options:
    -m, --memory MB      VM memory in MB (default: $MEMORY)
    -c, --cpus N         Number of vCPUs (default: $CPUS)
    -p, --port PORT      Host port to forward to enclave (default: $HOST_PORT)
    -g, --gpu BDF        GPU PCI address for passthrough (e.g., 0000:3b:00.0)
    --model-dir DIR      Host directory containing model weights to mount
    -h, --help           Show this help

Environment variables:
    MEMORY, CPUS, HOST_PORT, GUEST_PORT, GPU_BDF, MODEL_DIR

Examples:
    # CPU-only mode
    $0

    # With more memory
    $0 -m 16384 -c 8

    # With GPU passthrough (requires VFIO setup on host)
    $0 -g 0000:3b:00.0

    # With model directory mounted
    $0 --model-dir /path/to/models
EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -m|--memory)
            MEMORY="$2"
            shift 2
            ;;
        -c|--cpus)
            CPUS="$2"
            shift 2
            ;;
        -p|--port)
            HOST_PORT="$2"
            shift 2
            ;;
        -g|--gpu)
            GPU_BDF="$2"
            shift 2
            ;;
        --model-dir)
            MODEL_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Check for required files
if [ ! -f "$BR_IMG/vmlinux" ]; then
    echo "Error: Missing vmlinux - run build_buildroot_enclave.sh first"
    exit 1
fi

if [ ! -f "$BR_IMG/rootfs.ext2" ] && [ ! -f "$BR_IMG/rootfs.ext4" ]; then
    echo "Error: Missing rootfs image - run build_buildroot_enclave.sh first"
    exit 1
fi

# Determine rootfs file
ROOTFS=""
if [ -f "$BR_IMG/rootfs.ext4" ]; then
    ROOTFS="$BR_IMG/rootfs.ext4"
elif [ -f "$BR_IMG/rootfs.ext2" ]; then
    ROOTFS="$BR_IMG/rootfs.ext2"
fi

echo "=== muinference Weight Enclave VM ==="
echo "Memory: ${MEMORY}MB"
echo "CPUs: ${CPUS}"
echo "Host port: ${HOST_PORT} -> Guest port: ${GUEST_PORT}"
echo "Kernel: $BR_IMG/vmlinux"
echo "Rootfs: $ROOTFS"
if [ -n "$GPU_BDF" ]; then
    echo "GPU passthrough: $GPU_BDF"
fi
if [ -n "$MODEL_DIR" ]; then
    echo "Model directory: $MODEL_DIR"
fi
echo ""

# Build QEMU command
QEMU_CMD=(
    qemu-system-x86_64
    -enable-kvm
    -m "$MEMORY"
    -smp "$CPUS"
    -kernel "$BR_IMG/vmlinux"
    -append "root=/dev/vda console=ttyS0 quiet"
    -drive "file=$ROOTFS,format=raw,if=virtio"
    -netdev "user,id=net0,hostfwd=tcp::${HOST_PORT}-:${GUEST_PORT}"
    -device "virtio-net-pci,netdev=net0"
    -nographic
)

# Add model directory as virtio-9p share if specified
if [ -n "$MODEL_DIR" ]; then
    QEMU_CMD+=(
        -virtfs "local,path=$MODEL_DIR,mount_tag=models,security_model=passthrough,readonly=on"
    )
    echo "Note: Mount models in guest with: mount -t 9p -o trans=virtio models /opt/models"
fi

# Add GPU passthrough if specified
if [ -n "$GPU_BDF" ]; then
    echo ""
    echo "GPU Passthrough Setup Required:"
    echo "1. Unbind GPU from host driver:"
    echo "   echo '$GPU_BDF' > /sys/bus/pci/devices/$GPU_BDF/driver/unbind"
    echo "2. Bind to vfio-pci:"
    echo "   echo 'vfio-pci' > /sys/bus/pci/devices/$GPU_BDF/driver_override"
    echo "   echo '$GPU_BDF' > /sys/bus/pci/drivers/vfio-pci/bind"
    echo ""

    QEMU_CMD+=(
        -device "vfio-pci,host=$GPU_BDF,multifunction=on"
    )
fi

echo "Starting VM..."
echo "Connect to enclave from host: ./scripts/host_proxy_and_attest.py"
echo "Press Ctrl+A X to exit QEMU"
echo ""

exec "${QEMU_CMD[@]}"

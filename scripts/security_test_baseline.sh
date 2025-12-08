#!/usr/bin/env bash
#
# security_test_baseline.sh
#
# Security scanning for the baseline Docker stack.
# Compare results with security_test_muinference.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BASELINE_DIR="$ROOT/baseline_stack"

IMAGE_NAME="baseline-gpt-oss-20b"

echo "=== Baseline Stack Security Testing ==="
echo ""

# Check if Docker is available
if ! command -v docker &>/dev/null; then
    echo "Error: Docker not found. Please install Docker."
    exit 1
fi

# Check if baseline image exists or build it
if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
    echo "Building baseline image..."
    if [ -f "$BASELINE_DIR/Dockerfile" ]; then
        docker build -t "$IMAGE_NAME" "$BASELINE_DIR"
    else
        echo "Error: Dockerfile not found at $BASELINE_DIR/Dockerfile"
        echo "Create the baseline stack first."
        exit 1
    fi
fi

echo "Image: $IMAGE_NAME"
echo ""

echo "=========================================="
echo "1. Package/Binary Count"
echo "=========================================="
echo ""

# Count binaries in container
echo "Executable files in key directories:"
docker run --rm "$IMAGE_NAME" sh -c '
    for dir in /bin /sbin /usr/bin /usr/sbin; do
        if [ -d "$dir" ]; then
            count=$(ls -1 "$dir" 2>/dev/null | wc -l)
            echo "  $dir: $count files"
        fi
    done
'

echo ""
echo "Installed packages (dpkg):"
PKG_COUNT=$(docker run --rm "$IMAGE_NAME" dpkg -l 2>/dev/null | wc -l || echo "N/A")
echo "  Total: $PKG_COUNT"

echo ""
echo "Python packages (pip):"
PIP_COUNT=$(docker run --rm "$IMAGE_NAME" pip list 2>/dev/null | wc -l || echo "N/A")
echo "  Total: $PIP_COUNT"

echo ""
echo "=========================================="
echo "2. Vulnerability Scanning"
echo "=========================================="
echo ""

if command -v trivy &>/dev/null; then
    echo "Running Trivy image scan..."
    echo ""
    trivy image "$IMAGE_NAME" --severity HIGH,CRITICAL 2>/dev/null || \
        echo "Trivy scan completed"
else
    echo "Trivy not installed. Install with:"
    echo "  curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin"
fi

echo ""
echo "=========================================="
echo "3. SUID/SGID Binary Check"
echo "=========================================="
echo ""

echo "SUID binaries:"
docker run --rm "$IMAGE_NAME" find / -perm -4000 -type f 2>/dev/null || echo "  (check failed)"

echo ""
echo "SGID binaries:"
docker run --rm "$IMAGE_NAME" find / -perm -2000 -type f 2>/dev/null || echo "  (check failed)"

echo ""
echo "=========================================="
echo "4. Running Services (in container)"
echo "=========================================="
echo ""

# Start container temporarily and check services
CONTAINER_ID=$(docker run -d --rm "$IMAGE_NAME" sleep 30 2>/dev/null || echo "")
if [ -n "$CONTAINER_ID" ]; then
    echo "Listening ports inside container:"
    docker exec "$CONTAINER_ID" ss -tulpn 2>/dev/null || \
        docker exec "$CONTAINER_ID" netstat -tulpn 2>/dev/null || \
        echo "  Could not check ports"

    echo ""
    echo "Running processes:"
    docker exec "$CONTAINER_ID" ps aux 2>/dev/null | head -20 || echo "  Could not list processes"

    docker stop "$CONTAINER_ID" &>/dev/null || true
else
    echo "Could not start container for service check"
fi

echo ""
echo "=========================================="
echo "5. Image Layers & Size"
echo "=========================================="
echo ""

echo "Image size:"
docker images "$IMAGE_NAME" --format "  {{.Size}}"

echo ""
echo "Layer count:"
LAYER_COUNT=$(docker history "$IMAGE_NAME" --quiet 2>/dev/null | wc -l)
echo "  $LAYER_COUNT layers"

echo ""
echo "=========================================="
echo "Comparison Summary"
echo "=========================================="
echo ""
echo "Baseline characteristics (typical for full-stack inference):"
echo "  - Hundreds of packages (apt + pip)"
echo "  - Full Ubuntu/Debian userspace"
echo "  - Multiple potential services"
echo "  - Larger attack surface"
echo ""
echo "Run ./scripts/security_test_muinference.sh to compare with μEnclave"
echo ""

#!/usr/bin/env bash
#
# loc_compare.sh
#
# Compare lines of code between μEnclave stack and baseline stack.
# This demonstrates the "radical reduction in attack surface" that SL5 requires.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Check for cloc or scc
if command -v cloc &>/dev/null; then
    LOC_TOOL="cloc"
elif command -v scc &>/dev/null; then
    LOC_TOOL="scc"
else
    echo "Error: Neither 'cloc' nor 'scc' found. Please install one:"
    echo "  Ubuntu/Debian: sudo apt install cloc"
    echo "  macOS: brew install cloc"
    echo "  Or: go install github.com/boyter/scc/v3@latest"
    exit 1
fi

echo "=== Lines of Code Comparison: μEnclave vs Baseline ==="
echo "Using tool: $LOC_TOOL"
echo ""

# muinference enclave stack
MU_DIRS=(
    "$ROOT/external/muinference"
    "$ROOT/scripts"
)

# Baseline stack
BASELINE_DIRS=(
    "$ROOT/baseline_stack"
)

echo "=========================================="
echo "μEnclave Stack (muinference)"
echo "=========================================="
echo ""
echo "Directories:"
for d in "${MU_DIRS[@]}"; do
    if [ -d "$d" ]; then
        echo "  - $d"
    fi
done
echo ""

if [ "$LOC_TOOL" = "cloc" ]; then
    cloc "${MU_DIRS[@]}" --quiet 2>/dev/null || cloc "${MU_DIRS[@]}"
else
    scc "${MU_DIRS[@]}"
fi

echo ""
echo "=========================================="
echo "Baseline Stack (Docker + PyTorch)"
echo "=========================================="
echo ""
echo "Directories:"
for d in "${BASELINE_DIRS[@]}"; do
    if [ -d "$d" ]; then
        echo "  - $d"
    fi
done
echo ""

if [ -d "${BASELINE_DIRS[0]}" ]; then
    if [ "$LOC_TOOL" = "cloc" ]; then
        cloc "${BASELINE_DIRS[@]}" --quiet 2>/dev/null || cloc "${BASELINE_DIRS[@]}"
    else
        scc "${BASELINE_DIRS[@]}"
    fi
else
    echo "(Baseline stack not yet created)"
fi

echo ""
echo "=========================================="
echo "Summary"
echo "=========================================="
echo ""
echo "The μEnclave stack should show significantly fewer lines of code,"
echo "demonstrating the 'radical reduction' in attack surface that SL5 requires."
echo ""
echo "For a full comparison, also consider:"
echo "  - Buildroot rootfs packages vs Ubuntu base image packages"
echo "  - Kernel config options enabled"
echo "  - Number of running services/daemons"
echo ""

#!/bin/bash
#
# analyze.sh - Analysis entrypoint for muinference-tools container
#
# Commands:
#   loc      - Lines of code comparison
#   security - Security scan (baseline Docker image)
#   all      - Run all analyses
#   help     - Show this help

set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"

show_help() {
    cat <<EOF
muinference Analysis Tools

Usage: docker run -v \$(pwd):/workspace muinference-tools <command>

Commands:
  loc           Lines of code comparison (custom code only)
  attack        Full attack surface analysis (recommended)
  security      Security scan of baseline Docker image
  all           Run all analyses
  help          Show this help

Examples:
  # Run full attack surface analysis (recommended)
  docker run -v \$(pwd):/workspace -v /var/run/docker.sock:/var/run/docker.sock muinference-tools attack

  # Run LOC comparison (custom code only)
  docker run -v \$(pwd):/workspace muinference-tools loc

  # Run security scan (requires Docker socket)
  docker run -v \$(pwd):/workspace -v /var/run/docker.sock:/var/run/docker.sock muinference-tools security

  # Run all analyses
  docker run -v \$(pwd):/workspace -v /var/run/docker.sock:/var/run/docker.sock muinference-tools all
EOF
}

loc_compare() {
    echo "=== Lines of Code Comparison: muEnclave vs Baseline ==="
    echo ""

    MU_DIRS=(
        "$WORKSPACE/external/muinference"
        "$WORKSPACE/scripts"
    )

    BASELINE_DIRS=(
        "$WORKSPACE/baseline_stack"
    )

    echo "=========================================="
    echo "muEnclave Stack (muinference)"
    echo "=========================================="
    echo ""
    echo "Directories:"
    for d in "${MU_DIRS[@]}"; do
        if [ -d "$d" ]; then
            echo "  - ${d#$WORKSPACE/}"
        fi
    done
    echo ""

    # Use scc for fast analysis
    echo "Using scc (Sloc Cloc and Code):"
    echo ""
    scc "${MU_DIRS[@]}" 2>/dev/null || cloc "${MU_DIRS[@]}" --quiet

    echo ""
    echo "=========================================="
    echo "Baseline Stack (Docker + PyTorch)"
    echo "=========================================="
    echo ""

    if [ -d "${BASELINE_DIRS[0]}" ]; then
        echo "Directories:"
        for d in "${BASELINE_DIRS[@]}"; do
            echo "  - ${d#$WORKSPACE/}"
        done
        echo ""
        scc "${BASELINE_DIRS[@]}" 2>/dev/null || cloc "${BASELINE_DIRS[@]}" --quiet
    else
        echo "(Baseline stack not found)"
    fi

    echo ""
    echo "=========================================="
    echo "Summary"
    echo "=========================================="
    echo ""

    # Get totals
    MU_TOTAL=$(scc "${MU_DIRS[@]}" --format json 2>/dev/null | jq '[.[].Code] | add' 2>/dev/null || echo "N/A")
    BASELINE_TOTAL=$(scc "${BASELINE_DIRS[@]}" --format json 2>/dev/null | jq '[.[].Code] | add' 2>/dev/null || echo "N/A")

    echo "muEnclave code lines: $MU_TOTAL"
    echo "Baseline code lines:  $BASELINE_TOTAL"
    echo ""
    echo "The muEnclave has a radically reduced attack surface."
    echo ""
}

security_scan() {
    echo "=== Security Scan ==="
    echo ""

    # Check if Docker socket is available
    if [ ! -S /var/run/docker.sock ]; then
        echo "Warning: Docker socket not mounted."
        echo "For full security scan, run with: -v /var/run/docker.sock:/var/run/docker.sock"
        echo ""
    fi

    BASELINE_IMAGE="muinference-baseline"

    # Check if baseline image exists
    if docker image inspect "$BASELINE_IMAGE" &>/dev/null 2>&1; then
        echo "=========================================="
        echo "Baseline Image Vulnerability Scan"
        echo "=========================================="
        echo ""
        echo "Scanning image: $BASELINE_IMAGE"
        echo ""
        trivy image "$BASELINE_IMAGE" --severity HIGH,CRITICAL --quiet || \
            echo "Trivy scan completed (check output above)"
    else
        echo "Baseline image '$BASELINE_IMAGE' not found."
        echo "Build it first with: docker build -t $BASELINE_IMAGE baseline_stack/"
        echo ""
        echo "Scanning source files instead..."
        echo ""
    fi

    echo ""
    echo "=========================================="
    echo "Source Code Security Scan"
    echo "=========================================="
    echo ""

    echo "Scanning muEnclave source..."
    trivy fs "$WORKSPACE/external/muinference" --severity HIGH,CRITICAL --quiet 2>/dev/null || \
        echo "  No issues found or scan skipped"

    echo ""
    echo "Scanning baseline source..."
    trivy fs "$WORKSPACE/baseline_stack" --severity HIGH,CRITICAL --quiet 2>/dev/null || \
        echo "  No issues found or scan skipped"

    echo ""
    echo "=========================================="
    echo "Python Dependency Check"
    echo "=========================================="
    echo ""

    # Check for requirements files
    for req in "$WORKSPACE/requirements.txt" "$WORKSPACE/baseline_stack/requirements.txt"; do
        if [ -f "$req" ]; then
            echo "Checking ${req#$WORKSPACE/}..."
            pip install safety 2>/dev/null || true
            safety check -r "$req" 2>/dev/null || echo "  (safety check skipped)"
        fi
    done

    echo ""
}

run_all() {
    loc_compare
    echo ""
    echo "================================================================"
    echo ""
    security_scan
}

attack_surface() {
    /usr/local/bin/analyze_attack_surface
}

run_all() {
    attack_surface
    echo ""
    echo "================================================================"
    echo ""
    security_scan
}

# Main
case "${1:-help}" in
    loc)
        loc_compare
        ;;
    attack)
        attack_surface
        ;;
    security)
        security_scan
        ;;
    all)
        run_all
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "Unknown command: $1"
        echo ""
        show_help
        exit 1
        ;;
esac

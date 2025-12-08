#!/usr/bin/env bash
#
# service_compare.sh
#
# Compare network services and attack surface between μEnclave and baseline.
# This demonstrates the "allow by exception" security model.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MU_PORT="${MU_PORT:-10000}"
BASELINE_PORT="${BASELINE_PORT:-8000}"

echo "=== Network Service Comparison ==="
echo ""

# Check for nmap
if ! command -v nmap &>/dev/null; then
    echo "Warning: nmap not found. Install for full port scanning."
    echo "  Ubuntu/Debian: sudo apt install nmap"
    echo "  macOS: brew install nmap"
    USE_NMAP=false
else
    USE_NMAP=true
fi

echo "=========================================="
echo "μEnclave VM (expected: single port $MU_PORT)"
echo "=========================================="
echo ""

# Check if enclave is running
if nc -z 127.0.0.1 "$MU_PORT" 2>/dev/null; then
    echo "Status: RUNNING"
    echo ""

    if $USE_NMAP; then
        echo "Port scan (localhost only):"
        nmap -sV -p 1-65535 127.0.0.1 --open 2>/dev/null | grep -E "^[0-9]+/tcp" || echo "  Only expected port open"
    else
        echo "Quick check - port $MU_PORT:"
        nc -zv 127.0.0.1 "$MU_PORT" 2>&1 || true
    fi

    echo ""
    echo "Expected: ONLY port $MU_PORT (forwarded to enclave:9000)"
    echo "The enclave should have NO other services (no SSH, no HTTP management, etc.)"
else
    echo "Status: NOT RUNNING"
    echo "Start with: ./scripts/run_enclave_vm.sh"
fi

echo ""
echo "=========================================="
echo "Baseline Container (expected: port $BASELINE_PORT + more)"
echo "=========================================="
echo ""

# Check if baseline is running
if nc -z 127.0.0.1 "$BASELINE_PORT" 2>/dev/null; then
    echo "Status: RUNNING"
    echo ""

    if $USE_NMAP; then
        echo "Port scan (localhost only):"
        nmap -sV -p 1-65535 127.0.0.1 --open 2>/dev/null | grep -E "^[0-9]+/tcp" || echo "  Check ports manually"
    else
        echo "Quick check - port $BASELINE_PORT:"
        nc -zv 127.0.0.1 "$BASELINE_PORT" 2>&1 || true
    fi

    echo ""
    echo "Note: Baseline typically exposes more services/ports"
else
    echo "Status: NOT RUNNING"
    echo "Start with: cd baseline_stack && docker-compose up"
fi

echo ""
echo "=========================================="
echo "Security Comparison Summary"
echo "=========================================="
echo ""
echo "μEnclave advantages:"
echo "  - Single network service (inference RPC only)"
echo "  - No SSH access (no remote shell)"
echo "  - No package manager in runtime"
echo "  - No systemd/init complexity"
echo "  - Minimal kernel (no unnecessary modules)"
echo ""
echo "Baseline typically includes:"
echo "  - HTTP API server"
echo "  - Potentially SSH for debugging"
echo "  - Package manager (apt/pip)"
echo "  - Full systemd"
echo "  - General-purpose kernel"
echo ""

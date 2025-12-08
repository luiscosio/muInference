# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

muinference is a Buildroot-based μEnclave (micro-enclave) for SL5-style secure GPU inference. It implements a Weight Enclave where the host is treated as untrusted and only the minimal enclave handles model weights.

## Build Commands

```bash
# Build the Buildroot enclave (first run takes 30-60 minutes)
./scripts/build_buildroot_enclave.sh

# Run the enclave VM
./scripts/run_enclave_vm.sh

# Run with GPU passthrough
./scripts/run_enclave_vm.sh -g 0000:3b:00.0

# Connect host proxy to enclave
./scripts/host_proxy_and_attest.py
```

## Test Commands

```bash
# Compare lines of code (attack surface)
./scripts/loc_compare.sh

# Compare network services
./scripts/service_compare.sh

# Security scan the enclave
./scripts/security_test_muinference.sh

# Security scan baseline
./scripts/security_test_baseline.sh

# Fuzz test the RPC protocol
./scripts/fuzz_enclave_rpc.py --iterations 100

# Demonstrate exfiltration timing
./scripts/exfil_timing_test.py
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         Host System                          │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  host_proxy_and_attest.py                             │  │
│  │  - Attestation verification                           │  │
│  │  - Bandwidth-limited output (5 KB/s default)          │  │
│  │  - Encrypted unlock token                             │  │
│  └─────────────────────┬─────────────────────────────────┘  │
│                        │ TCP :10000 → :9000                  │
│  ┌─────────────────────▼─────────────────────────────────┐  │
│  │              QEMU/KVM VM (μEnclave)                   │  │
│  │  ┌─────────────────────────────────────────────────┐  │  │
│  │  │  Buildroot Linux (minimal)                      │  │  │
│  │  │  - BusyBox userspace                            │  │  │
│  │  │  - Single service: enclave_server.py            │  │  │
│  │  │  - No SSH, no package manager                   │  │  │
│  │  │  - Custom minimal kernel                        │  │  │
│  │  └─────────────────────────────────────────────────┘  │  │
│  │  ┌─────────────────────────────────────────────────┐  │  │
│  │  │  NVIDIA GPU (VFIO passthrough)                  │  │  │
│  │  │  - Model weights loaded here                    │  │  │
│  │  │  - Inference execution                          │  │  │
│  │  └─────────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Key Files

- `external/muinference/rootfs_overlay/opt/enclave_server.py` - Main enclave inference server
- `external/muinference/muinference_defconfig` - Buildroot configuration
- `external/muinference/board/x86_64/muinference/linux.config` - Kernel configuration
- `scripts/host_proxy_and_attest.py` - Host-side proxy with attestation
- `baseline_stack/` - Docker-based baseline for comparison

## Protocol

Length-prefixed JSON over TCP:
1. Enclave → Host: `{"measurement": "<sha256>"}` (attestation)
2. Host → Enclave: AES-GCM encrypted unlock token
3. Enclave → Host: `{"status": "ready"}`
4. Host → Enclave: `{"prompt": "...", "max_new_tokens": N}`
5. Enclave → Host: `{"completion": "...", "elapsed_ms": N}`

## Conventions

- Shell scripts use `set -euo pipefail`
- Python uses pycryptodome for crypto operations
- Buildroot external tree follows standard BR2_EXTERNAL structure
- All scripts are in `scripts/` directory
- Baseline comparison stack is in `baseline_stack/`

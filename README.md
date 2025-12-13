# muinference

**Weight Enclave for SL5-style GPU Inference**

muinference implements a minimal Weight Enclave for secure AI model inference, following the SL5 (Security Level 5) security model. The host system is treated as untrusted; only the enclave handles model weights.

## Quick Start

### Prerequisites

- Docker Desktop (Windows, macOS, or Linux)
- Python 3.10+ with pip (for local testing)

### Option A: Quick Test (No VM)

Test the enclave server directly without building the full Buildroot VM:

```bash
# Clone and enter directory
git clone https://github.com/luiscosio/muInference.git
cd muInference

# Create Python virtual environment
python -m venv venv
source venv/bin/activate  # Linux/macOS
# or: venv\Scripts\activate  # Windows

# Install dependencies
pip install pycryptodome torch transformers accelerate

# Terminal 1: Start enclave server
python external/muinference/rootfs_overlay/opt/enclave_server.py

# Terminal 2: Connect with host proxy
python scripts/host_proxy_and_attest.py --port 9000

# Type prompts and get responses!
```

### Option B: Full Build with Docker

Build everything using Docker (includes Buildroot VM):

```bash
# Clone repository
git clone https://github.com/luiscosio/muInference.git
cd muInference

# Build the Buildroot enclave VM (first build: 30-60 min, cached after)
docker compose -f docker-compose.build.yml run buildroot

# Run attack surface analysis
docker compose -f docker-compose.build.yml run tools attack

# Run security scan
docker compose -f docker-compose.build.yml run tools security
```

### Option C: Run E2E Test

Automated test that starts server, connects, and runs inference:

```bash
# With venv activated
python test/e2e_test.py
```

## Overview

This project provides:

1. **muEnclave**: A Buildroot-based minimal Linux VM that runs GPU inference with a radically reduced attack surface
2. **Host Proxy**: Bandwidth-limited proxy with attestation for communicating with the enclave
3. **Baseline Stack**: Realistic Docker-based inference for security comparison
4. **Security Tools**: Scripts for comparing attack surface and running security tests

## Repository Structure

```
muinference/
├── docker/
│   ├── Dockerfile.buildroot          # Buildroot build environment
│   ├── Dockerfile.baseline-realistic # Realistic baseline for comparison
│   ├── Dockerfile.tools              # Analysis tools (scc, trivy)
│   ├── analyze.sh                    # Analysis entrypoint
│   └── analyze_attack_surface.sh     # Full attack surface analysis
├── docker-compose.build.yml          # Build orchestration
├── external/
│   └── muinference/                  # Buildroot external tree
│       ├── board/x86_64/muinference/
│       │   ├── linux.config          # Minimal kernel config
│       │   └── post_build.sh
│       ├── rootfs_overlay/
│       │   ├── etc/muinference.conf
│       │   └── opt/enclave_server.py # Main enclave server
│       └── muinference_defconfig
├── scripts/
│   ├── build_buildroot_enclave.sh    # Build the VM
│   ├── host_proxy_and_attest.py      # Host-side proxy
│   ├── exfil_timing_test.py          # Bandwidth analysis
│   └── fuzz_enclave_rpc.py           # Protocol fuzzer
├── baseline_stack/                    # Docker baseline for comparison
│   ├── Dockerfile
│   ├── docker-compose.yml
│   └── server.py
└── test/
    └── e2e_test.py                   # End-to-end test
```

## Protocol

The enclave uses a simple length-prefixed JSON protocol:

```
1. Enclave -> Host: {"measurement": "<sha256>"}     # Attestation
2. Host -> Enclave: <AES-GCM encrypted token>       # Unlock
3. Enclave -> Host: {"status": "ready"}             # Ready
4. Host -> Enclave: {"prompt": "...", "max_new_tokens": N}  # Request
5. Enclave -> Host: {"completion": "...", "elapsed_ms": N}  # Response
```

## Model Setup

**Default Model**: [unsloth/Llama-3.2-3B-Instruct](https://huggingface.co/unsloth/Llama-3.2-3B-Instruct)

- 3.2 billion parameters
- Instruction-tuned for chat/assistant tasks
- ~6GB in BF16 precision
- Optimized by Unsloth for faster inference

The model auto-downloads from Hugging Face on first run. To pre-download:

```bash
pip install huggingface_hub
huggingface-cli download unsloth/Llama-3.2-3B-Instruct
```

For offline deployment, download to a local directory:

```bash
huggingface-cli download unsloth/Llama-3.2-3B-Instruct --local-dir ./models/Llama-3.2-3B-Instruct
export MODEL_PATH=./models/Llama-3.2-3B-Instruct
```

## Configuration

### Enclave Server

Environment variables:
- `MODEL_PATH`: Path to model weights (default: downloads from HuggingFace)
- `ENCLAVE_PORT`: Listen port (default: 9000)

### Host Proxy

```bash
python scripts/host_proxy_and_attest.py \
    --host 127.0.0.1 \
    --port 9000 \
    --rate-kb 5 \
    --expected-measurement <hash>
```

## Caching

muinference uses Docker's native caching:

- **Docker images**: Built once, reused automatically
- **Buildroot cache**: Stored in `muinference-buildroot-cache` Docker volume
- **Model weights**: Cached by HuggingFace in `~/.cache/huggingface`

To force a full rebuild:
```bash
docker compose -f docker-compose.build.yml build --no-cache buildroot
```

To clear the Buildroot cache:
```bash
docker volume rm muinference-buildroot-cache
```

## Security Analysis

```bash
# Full attack surface analysis (recommended)
docker compose -f docker-compose.build.yml run tools attack

# Custom code LOC only
docker compose -f docker-compose.build.yml run tools loc

# Vulnerability scan
docker compose -f docker-compose.build.yml run tools security

# All analyses
docker compose -f docker-compose.build.yml run tools all
```

## Troubleshooting

### Docker build fails

Make sure Docker Desktop is running:
```bash
docker --version
docker compose version
```

### Model download slow/fails

Pre-download the model:
```bash
pip install huggingface_hub
huggingface-cli download unsloth/Llama-3.2-3B-Instruct
```

### Clear all caches and rebuild

```bash
# Remove Docker images and volumes
docker compose -f docker-compose.build.yml down --rmi all --volumes

# Rebuild from scratch
docker compose -f docker-compose.build.yml build --no-cache
docker compose -f docker-compose.build.yml run buildroot
```

---

# Security Model

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              UNTRUSTED HOST                                 │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                         Host Proxy                                    │  │
│  │  • Attestation verification (SHA256 measurement)                      │  │
│  │  • Bandwidth limiting (5 KB/s egress)                                 │  │
│  │  • AES-GCM encrypted unlock tokens                                    │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                    │                                        │
│                          TCP :9000 │ (rate-limited)                         │
│                                    ▼                                        │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                     WEIGHT ENCLAVE (VM)                               │  │
│  │  ┌─────────────────────────────────────────────────────────────────┐  │  │
│  │  │              Buildroot Linux (~50MB rootfs)                     │  │  │
│  │  │  • Minimal kernel (Linux 6.6.22)                                │  │  │
│  │  │  • BusyBox userspace (~400K LOC)                                │  │  │
│  │  │  • No SSH, no package manager, single service                   │  │  │
│  │  └─────────────────────────────────────────────────────────────────┘  │  │
│  │                                │                                      │  │
│  │  ┌─────────────────────────────▼─────────────────────────────────┐    │  │
│  │  │                    Enclave Server                              │    │  │
│  │  │  • Receives attestation challenge                              │    │  │
│  │  │  • Decrypts unlock token (AES-GCM)                             │    │  │
│  │  │  • Loads model weights (in-enclave only)                       │    │  │
│  │  │  • Runs inference (PyTorch/Transformers)                       │    │  │
│  │  └─────────────────────────────┬─────────────────────────────────┘    │  │
│  │                                │                                      │  │
│  │  ┌─────────────────────────────▼─────────────────────────────────┐    │  │
│  │  │                 Model Weights (Protected)                      │    │  │
│  │  │  • Llama-3.2-3B-Instruct (~6GB BF16)                           │    │  │
│  │  │  • Never leave enclave boundary                                │    │  │
│  │  │  • Exfiltration: ~14 days at 5 KB/s                            │    │  │
│  │  └───────────────────────────────────────────────────────────────┘    │  │
│  │                                │                                      │  │
│  │  ┌─────────────────────────────▼─────────────────────────────────┐    │  │
│  │  │                    GPU (VFIO Passthrough)                      │    │  │
│  │  │  • Direct hardware access inside enclave                       │    │  │
│  │  │  • Isolated from host via IOMMU                                │    │  │
│  │  └───────────────────────────────────────────────────────────────┘    │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘

                            INFERENCE FLOW
                            ==============

  User ──► Host Proxy ──► [Attestation Check] ──► Enclave Server
              │                                        │
              │         ┌──────────────────────────────┘
              │         │
              │         ▼
              │    [Decrypt Unlock Token]
              │         │
              │         ▼
              │    [Load Model Weights]
              │         │
              │         ▼
              └──► [Rate-Limited Response] ◄── [GPU Inference]
                     (5 KB/s max)
```

## SL5 Weight Enclave Controls

muinference implements key SL5 Weight Enclave controls:

| Control | Implementation |
|---------|----------------|
| Minimal OS | Buildroot with busybox, ~50MB rootfs (~500K LOC) |
| Allow-by-exception | Single port 9000, no SSH/management |
| Attestation | SHA256 measurement hash of server + kernel |
| Bandwidth limiting | 5 KB/s default egress rate |
| Weight protection | AES-GCM encrypted unlock, in-enclave only |
| Host isolation | KVM/QEMU VM boundary |
| GPU isolation | VFIO passthrough (optional) |

### Key Security Properties

- **Minimal OS**: Buildroot-based system with only essential packages (~500K LOC vs ~100M)
- **Allow-by-Exception**: Single network service, no SSH, no package manager at runtime
- **Attestation**: Host verifies enclave measurement before unlocking weights
- **Bandwidth Limiting**: Output rate-limited to make weight exfiltration impractical
- **GPU Passthrough**: NVIDIA GPU runs inside the enclave via VFIO (optional)

## Attack Surface Comparison

The key security benefit of muinference is the **radical reduction in attack surface** compared to typical inference deployments.

### Full Stack Comparison

| Component | muEnclave | Typical Inference Server |
|-----------|----------|--------------------------|
| **Base OS** | Buildroot + BusyBox | Ubuntu 22.04 Server |
| OS Packages | ~10-20 | ~500-800 |
| OS Binaries | ~100-200 | ~2,000-3,000 |
| OS LOC (est.) | ~500K | ~50-100M |
| **Python Runtime** | Minimal (inference only) | Full CPython |
| pip packages | 0 at runtime | 50-100+ |
| **GPU Stack** | VFIO passthrough | Full CUDA runtime (~500MB) |
| **Network Services** | 1 port (9000) | SSH, API, monitoring, etc. |
| **Package Managers** | None at runtime | apt + pip available |
| **Image/Rootfs Size** | ~50MB | ~10-20GB |
| **Attack Surface Ratio** | **1x** | **~100-500x larger** |

### LOC Estimates (Industry Data)

| Component | Lines of Code | Source |
|-----------|---------------|--------|
| Linux kernel | ~30M | [OpenHub](https://www.openhub.net/p/linux) |
| Ubuntu userspace | ~50-100M | Aggregate |
| BusyBox | ~400K | [OpenHub](https://www.openhub.net/p/busybox) |
| PyTorch | ~3M | GitHub |
| vLLM | ~100K | GitHub |
| Transformers | ~500K | GitHub |

### Exfiltration Analysis

At 5 KB/s bandwidth limit:

| Model | Size | Exfil Time |
|-------|------|------------|
| Llama-3.2-3B-Instruct (BF16) | 6 GB | ~14 days |
| LLaMA-70B (FP16) | 140 GB | ~324 days |
| GPT-3 175B (FP16) | 350 GB | ~2.2 years |

---

## TODO: seL4 Migration

The current implementation uses QEMU/KVM for VM isolation. The planned production architecture will use **seL4** as the formally verified microkernel:

```
┌─────────────────────────────────────────────────────────────────┐
│                    seL4 Microkernel (Host)                      │
│              Formally verified isolation anchor                 │
│    • Mathematical proof of isolation properties                 │
│    • ~10K LOC kernel (vs ~30M for Linux)                        │
│    • Eliminates entire classes of kernel vulnerabilities        │
├─────────────────────────────────────────────────────────────────┤
│                         CAmkES                                  │
│              Component architecture framework                   │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐  │
│  │  Buildroot VM   │  │  File Server    │  │  Serial Server  │  │
│  │  (Guest Linux)  │  │                 │  │                 │  │
│  │                 │  │                 │  │                 │  │
│  │  Candle         │  │                 │  │                 │  │
│  │                 │  │                 │  │                 │  │
│  └────────┬────────┘  └─────────────────┘  └─────────────────┘  │
│           │                                                     │
│           ▼                                                     │
│  ┌─────────────────┐                                            │
│  │  GPU (VFIO)     │  Why Linux VM is needed:                   │
│  │                 │  • NVIDIA drivers require Linux            │
│  └─────────────────┘  • seL4 cannot directly drive GPUs         │
└─────────────────────────────────────────────────────────────────┘
```

### seL4 Benefits

- **Formal Verification**: Mathematical proof that the kernel correctly enforces isolation
- **Minimal TCB**: ~10,000 LOC vs ~30 million for Linux kernel
- **No Undefined Behavior**: Verified absence of buffer overflows, null pointer dereferences, etc.
- **Proven Isolation**: Components cannot interfere with each other except through defined interfaces

### Migration Path

1. Set up seL4 + CAmkES build environment
2. Configure CAmkES VM component to host Buildroot Linux guest
3. Implement file server for kernel/rootfs images
4. Pass GPU through to guest VM via VFIO
5. Integrate attestation with seL4's secure boot chain

See `docs/` for detailed CAmkES VM setup instructions.

---

## License

Apache 2.0

## References

- [Llama-3.2-3B-Instruct on Hugging Face](https://huggingface.co/unsloth/Llama-3.2-3B-Instruct)
- [Buildroot Documentation](https://buildroot.org/docs.html)
- [seL4 Microkernel](https://sel4.systems/)
- [CAmkES Documentation](https://docs.sel4.systems/projects/camkes/)
- [QEMU/KVM Documentation](https://www.qemu.org/documentation/)
- [VFIO GPU Passthrough](https://wiki.archlinux.org/title/PCI_passthrough_via_OVMF)
- [OpenHub - Open Source LOC Statistics](https://www.openhub.net/)

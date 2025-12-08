# muinference

**Buildroot-based μEnclave for SL5-style GPU Inference**

muinference implements a minimal Weight Enclave for secure AI model inference, following the SL5 (Security Level 5) security model. The host system is treated as untrusted; only the enclave handles model weights.

## Model

**[unsloth/Llama-3.2-3B-Instruct](https://huggingface.co/unsloth/Llama-3.2-3B-Instruct)**

- 3.2 billion parameters
- Instruction-tuned for chat/assistant tasks
- ~6GB in BF16 precision
- Optimized by Unsloth for faster inference

## Quick Start

### Option A: Quick Test (No VM, ~5 minutes)

Test the enclave server directly without building the full Buildroot VM:

```bash
# Clone and enter directory
git clone https://github.com/luiscosio/muInference.git
cd muInference
git checkout buildroot-enclave

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

### Option B: Build with Docker (Recommended)

Build everything using Docker - no WSL or Linux required:

```bash
# Clone repository
git clone https://github.com/luiscosio/muInference.git
cd muInference
git checkout buildroot-enclave

# Build the Buildroot enclave VM (first build takes 30-60 min)
docker compose -f docker-compose.build.yml run buildroot

# Run LOC comparison
docker compose -f docker-compose.build.yml run tools loc

# Run security scan
docker compose -f docker-compose.build.yml run tools security

# Run all analyses
docker compose -f docker-compose.build.yml run tools all
```

### Option C: Full Buildroot VM on Linux

Build and run the complete minimal Linux VM (requires native Linux):

```bash
# 1. Install system dependencies (Ubuntu/Debian)
sudo apt update
sudo apt install -y build-essential git wget cpio unzip rsync bc \
    libncurses5-dev libssl-dev python3 python3-pip python3-venv \
    qemu-system-x86

# 2. Clone repository
git clone https://github.com/luiscosio/muInference.git
cd muInference
git checkout buildroot-enclave

# 3. Setup Python environment
python3 -m venv ~/muinference-venv
source ~/muinference-venv/bin/activate
pip install pycryptodome torch transformers accelerate

# 4. Make scripts executable
chmod +x scripts/*.sh scripts/*.py

# 5. Build Buildroot enclave (30-60 minutes first time)
./scripts/build_buildroot_enclave.sh

# 6. Run the VM (Terminal 1)
./scripts/run_enclave_vm.sh

# 7. Connect from host (Terminal 2)
source ~/muinference-venv/bin/activate
./scripts/host_proxy_and_attest.py --port 10000
```

### Option D: Run E2E Test

Automated test that starts server, connects, and runs inference:

```bash
# With venv activated
python test/e2e_test.py
```

## Overview

This project provides:

1. **μEnclave**: A Buildroot-based minimal Linux VM that runs GPU inference with a radically reduced attack surface
2. **Host Proxy**: Bandwidth-limited proxy with attestation for communicating with the enclave
3. **Baseline Stack**: Standard Docker-based inference for security comparison
4. **Security Tools**: Scripts for comparing attack surface and running security tests

### Key Security Properties

- **Minimal OS**: Buildroot-based system with only essential packages
- **Allow-by-Exception**: Single network service, no SSH, no package manager at runtime
- **Attestation**: Host verifies enclave measurement before unlocking weights
- **Bandwidth Limiting**: Output rate-limited to make weight exfiltration impractical
- **GPU Passthrough**: NVIDIA GPU runs inside the enclave (optional)

## Repository Structure

```
muinference/
├── docker/
│   ├── Dockerfile.buildroot    # Buildroot build environment
│   ├── Dockerfile.tools        # LOC/security analysis tools
│   └── analyze.sh              # Analysis entrypoint script
├── docker-compose.build.yml    # Build orchestration
├── external/
│   └── muinference/            # Buildroot external tree
│       ├── board/x86_64/muinference/
│       │   ├── linux.config    # Minimal kernel config
│       │   └── post_build.sh
│       ├── rootfs_overlay/
│       │   ├── etc/muinference.conf
│       │   └── opt/enclave_server.py  # Main enclave server
│       └── muinference_defconfig
├── scripts/
│   ├── build_buildroot_enclave.sh     # Build the VM
│   ├── run_enclave_vm.sh              # Run with QEMU
│   ├── host_proxy_and_attest.py       # Host-side proxy
│   ├── exfil_timing_test.py           # Bandwidth analysis
│   └── fuzz_enclave_rpc.py            # Protocol fuzzer
├── baseline_stack/                     # Docker baseline for comparison
│   ├── Dockerfile
│   ├── docker-compose.yml
│   └── server.py
└── test/
    └── e2e_test.py                    # End-to-end test
```

## Protocol

The enclave uses a simple length-prefixed JSON protocol:

```
1. Enclave → Host: {"measurement": "<sha256>"}     # Attestation
2. Host → Enclave: <AES-GCM encrypted token>       # Unlock
3. Enclave → Host: {"status": "ready"}             # Ready
4. Host → Enclave: {"prompt": "...", "max_new_tokens": N}  # Request
5. Enclave → Host: {"completion": "...", "elapsed_ms": N}  # Response
```

## Security Analysis Tools

```bash
# Using Docker (recommended)
docker compose -f docker-compose.build.yml run tools loc       # LOC comparison
docker compose -f docker-compose.build.yml run tools security  # Security scan
docker compose -f docker-compose.build.yml run tools all       # All analyses

# Native Linux (alternative)
./scripts/loc_compare.sh                      # Compare lines of code
python scripts/exfil_timing_test.py           # Analyze exfiltration timing
python scripts/fuzz_enclave_rpc.py --iterations 100  # Fuzz test RPC
./scripts/security_test_muinference.sh        # Security scan (requires trivy)
./scripts/security_test_baseline.sh           # Baseline security scan
```

## Model Setup

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

## GPU Passthrough (Optional)

For NVIDIA GPU passthrough:

1. Enable IOMMU in BIOS and kernel (`intel_iommu=on` or `amd_iommu=on`)

2. Unbind GPU from host driver:
```bash
GPU_BDF="0000:3b:00.0"  # Your GPU's PCI address
echo "$GPU_BDF" > /sys/bus/pci/devices/$GPU_BDF/driver/unbind
echo "vfio-pci" > /sys/bus/pci/devices/$GPU_BDF/driver_override
echo "$GPU_BDF" > /sys/bus/pci/drivers/vfio-pci/bind
```

3. Run VM with GPU:
```bash
./scripts/run_enclave_vm.sh -g 0000:3b:00.0
```

## Security Model

muinference implements key SL5 Weight Enclave controls:

| Control | Implementation |
|---------|----------------|
| Minimal OS | Buildroot with busybox, ~50MB rootfs |
| Allow-by-exception | Single port 9000, no SSH/management |
| Attestation | Measurement hash of server + kernel |
| Bandwidth limiting | 5 KB/s default egress rate |
| Weight protection | Encrypted unlock, in-enclave only |
| Host isolation | KVM/QEMU VM boundary |
| GPU isolation | VFIO passthrough (optional) |

### Exfiltration Analysis

At 5 KB/s bandwidth limit:

| Model | Size | Exfil Time |
|-------|------|------------|
| Llama-3.2-3B-Instruct (BF16) | 6 GB | ~14 days |
| LLaMA-70B (FP16) | 140 GB | ~324 days |
| GPT-3 175B (FP16) | 350 GB | ~2.2 years |

## Configuration

### Enclave Server

Environment variables:
- `MODEL_PATH`: Path to model weights (default: downloads from HuggingFace)
- `ENCLAVE_PORT`: Listen port (default: 9000)

### Host Proxy

```bash
./scripts/host_proxy_and_attest.py \
    --host 127.0.0.1 \
    --port 9000 \
    --rate-kb 5 \
    --expected-measurement <hash>
```

## Troubleshooting

### Docker build fails

Make sure Docker Desktop is running:
```bash
docker --version
docker compose version
```

### WSL/Linux: "externally-managed-environment" error

Create venv in Linux filesystem, not Windows mount:
```bash
python3 -m venv ~/muinference-venv
source ~/muinference-venv/bin/activate
pip install pycryptodome torch transformers accelerate
```

### WSL: "PATH contains spaces" error

Run builds from a native Linux path, not /mnt/c or /mnt/e:
```bash
mkdir -p ~/muinference-build
cd ~/muinference-build
git clone -b buildroot-enclave https://github.com/luiscosio/muInference.git
cd muInference
./scripts/build_buildroot_enclave.sh
```

Or use Docker (recommended - avoids all WSL issues):
```bash
docker compose -f docker-compose.build.yml run buildroot
```

### Model download slow/fails

Pre-download the model:
```bash
pip install huggingface_hub
huggingface-cli download unsloth/Llama-3.2-3B-Instruct
```

### QEMU fails to start

Ensure KVM is available:
```bash
sudo apt install qemu-system-x86 qemu-kvm
sudo usermod -aG kvm $USER
# Log out and back in
```

## License

Apache 2.0

## References

- [Llama-3.2-3B-Instruct on Hugging Face](https://huggingface.co/unsloth/Llama-3.2-3B-Instruct)
- [Buildroot Documentation](https://buildroot.org/docs.html)
- [QEMU/KVM Documentation](https://www.qemu.org/documentation/)
- [VFIO GPU Passthrough](https://wiki.archlinux.org/title/PCI_passthrough_via_OVMF)

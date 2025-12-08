# muinference

**Buildroot-based μEnclave for SL5-style GPU Inference**

muinference implements a minimal Weight Enclave for secure AI model inference, following the SL5 (Security Level 5) security model. The host system is treated as untrusted; only the enclave handles model weights.

## Model

**[unsloth/Llama-3.2-3B-Instruct](https://huggingface.co/unsloth/Llama-3.2-3B-Instruct)**

- 3.2 billion parameters
- Instruction-tuned for chat/assistant tasks
- ~6GB in BF16 precision
- Optimized by Unsloth for faster inference

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
├── buildroot/              # Buildroot checkout (created by build script)
├── external/
│   └── muinference/        # Buildroot external tree
│       ├── Config.in
│       ├── external.mk
│       ├── external.desc
│       ├── muinference_defconfig
│       ├── board/x86_64/muinference/
│       │   ├── linux.config
│       │   └── post_build.sh
│       ├── package/muinference-enclave/
│       │   ├── Config.in
│       │   └── muinference-enclave.mk
│       └── rootfs_overlay/
│           ├── etc/muinference.conf
│           └── opt/enclave_server.py
├── scripts/
│   ├── build_buildroot_enclave.sh
│   ├── run_enclave_vm.sh
│   ├── host_proxy_and_attest.py
│   ├── loc_compare.sh
│   ├── service_compare.sh
│   ├── security_test_muinference.sh
│   ├── security_test_baseline.sh
│   ├── fuzz_enclave_rpc.py
│   └── exfil_timing_test.py
└── baseline_stack/
    ├── Dockerfile
    ├── docker-compose.yml
    ├── server.py
    └── requirements.txt
```

## Quick Start

### Prerequisites

- Linux host with KVM support
- QEMU with KVM (`qemu-system-x86_64`)
- Git
- Build tools (`make`, `gcc`, etc.)
- Python 3.8+ with `pycryptodome`
- (Optional) NVIDIA GPU with VFIO setup for GPU passthrough
- (Optional) Docker for baseline comparison

### 1. Build the Enclave

```bash
# Make scripts executable
chmod +x scripts/*.sh scripts/*.py

# Build Buildroot enclave (takes 30-60 minutes first time)
./scripts/build_buildroot_enclave.sh
```

### 2. Run the Enclave VM

```bash
# Start the enclave VM (CPU-only mode)
./scripts/run_enclave_vm.sh

# With more resources
./scripts/run_enclave_vm.sh -m 16384 -c 8

# With GPU passthrough (requires VFIO setup)
./scripts/run_enclave_vm.sh -g 0000:3b:00.0
```

### 3. Connect from Host

In a separate terminal:

```bash
# Install host dependencies
pip install pycryptodome

# Connect to enclave
./scripts/host_proxy_and_attest.py

# With custom settings
./scripts/host_proxy_and_attest.py --port 10000 --rate-kb 5
```

### 4. Run Security Comparisons

```bash
# Compare lines of code
./scripts/loc_compare.sh

# Compare network services
./scripts/service_compare.sh

# Security scan muinference
./scripts/security_test_muinference.sh

# Security scan baseline
cd baseline_stack && docker build -t baseline-llama-3.2-3b .
./scripts/security_test_baseline.sh

# Demonstrate exfil timing
./scripts/exfil_timing_test.py

# Fuzz test the RPC protocol
./scripts/fuzz_enclave_rpc.py --iterations 100
```

## Protocol

The enclave uses a simple length-prefixed JSON protocol:

1. **Attestation**: Enclave sends `{"measurement": "<sha256>"}`
2. **Unlock**: Host sends AES-GCM encrypted token
3. **Ready**: Enclave responds `{"status": "ready"}`
4. **Inference**: Host sends `{"prompt": "...", "max_new_tokens": N}`
5. **Response**: Enclave returns `{"completion": "...", "elapsed_ms": N}`

## Model Setup

The model is automatically downloaded from Hugging Face on first run. To pre-download:

```bash
# Pre-download model weights (recommended)
pip install huggingface_hub
huggingface-cli download unsloth/Llama-3.2-3B-Instruct

# Or use Python
python -c "from transformers import AutoModelForCausalLM; AutoModelForCausalLM.from_pretrained('unsloth/Llama-3.2-3B-Instruct')"
```

For offline/air-gapped deployment:

```bash
# Download to local directory
huggingface-cli download unsloth/Llama-3.2-3B-Instruct --local-dir ./models/Llama-3.2-3B-Instruct

# For VM with 9p mount
./scripts/run_enclave_vm.sh --model-dir ./models

# Inside enclave, mount with:
mount -t 9p -o trans=virtio models /opt/models

# Set MODEL_PATH environment variable
export MODEL_PATH=/opt/models/Llama-3.2-3B-Instruct
```

For the baseline Docker stack:
```bash
# The baseline will auto-download from HuggingFace
cd baseline_stack && docker-compose up

# Or mount cached weights
docker-compose up  # Uses ~/.cache/huggingface mount
```

## GPU Passthrough

For NVIDIA GPU passthrough:

1. **Enable IOMMU** in BIOS and kernel (`intel_iommu=on` or `amd_iommu=on`)

2. **Unbind GPU from host driver**:
```bash
GPU_BDF="0000:3b:00.0"  # Your GPU's PCI address
echo "$GPU_BDF" > /sys/bus/pci/devices/$GPU_BDF/driver/unbind
echo "vfio-pci" > /sys/bus/pci/devices/$GPU_BDF/driver_override
echo "$GPU_BDF" > /sys/bus/pci/drivers/vfio-pci/bind
```

3. **Run VM with GPU**:
```bash
./scripts/run_enclave_vm.sh -g 0000:3b:00.0
```

## Configuration

### Enclave Configuration (`/etc/muinference.conf`)

```ini
listen_port=9000
max_egress_rate_kbps=5
max_response_tokens=2048
```

### Host Proxy Options

```bash
./scripts/host_proxy_and_attest.py \
    --host 127.0.0.1 \
    --port 10000 \
    --rate-kb 5 \
    --expected-measurement <hash>
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

## Development

### Customizing the Kernel

Edit `external/muinference/board/x86_64/muinference/linux.config` and rebuild.

### Adding Packages

1. Create package in `external/muinference/package/<name>/`
2. Add to `Config.in`
3. Enable in defconfig
4. Rebuild

### Moving to Production

For production deployment:

1. Replace Python server with Rust binary (llama.cpp)
2. Enable TPM-based attestation
3. Use hardware security module for key storage
4. Implement proper key derivation
5. Add monitoring and audit logging

## Comparison with Baseline

Run the comparison tools to see the security improvements:

```bash
# LOC comparison
./scripts/loc_compare.sh

# Output shows muinference has ~10x fewer lines of code

# Service comparison
./scripts/service_compare.sh

# Output shows single port vs multiple services

# Vulnerability scan
./scripts/security_test_muinference.sh
./scripts/security_test_baseline.sh

# Compare CVE counts and attack surface
```

## License

Apache 2.0

## References

- [Llama-3.2-3B-Instruct on Hugging Face](https://huggingface.co/unsloth/Llama-3.2-3B-Instruct)
- [Buildroot Documentation](https://buildroot.org/docs.html)
- [QEMU/KVM Documentation](https://www.qemu.org/documentation/)
- [VFIO GPU Passthrough](https://wiki.archlinux.org/title/PCI_passthrough_via_OVMF)

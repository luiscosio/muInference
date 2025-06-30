# μInference

Research platform for micro inference server for SL5

## Overview

μInference creates a minimal bootable Linux ISO with embedded LLaMA model inference capabilities. It packages [llama2.c](https://github.com/karpathy/llama2.c) into a custom Linux distribution that boots directly into an inference environment.

## Quick Start

### Prerequisites (Ubuntu/WSL2)

```bash
sudo apt update && sudo apt install -y \
    build-essential gcc g++ make git wget curl \
    xorriso mtools dosfstools \
    flex bison bc kmod cpio \
    libelf-dev libssl-dev \
    libncurses-dev \
    qemu-system-x86 \
    lld nasm
```

### Build

```bash
# Clone and build
git clone https://github.com/luiscosio/muinference
cd muinference
make iso

# Test in QEMU
make boot_iso
```

## Usage

Once booted, you can interact with the LLaMA model using the `talk` command:

```bash
# Ask a question
talk "What is the meaning of life?"

# Tell a story
talk "Tell me a story about a robot"
```

## Build Options

```bash
make help          # Show all targets
make iso           # Build ISO (default)
make boot_iso      # Test in QEMU
make clean         # Clean build artifacts
make distclean     # Remove all sources
```

### Speed up builds:
```bash
make fast-build    # Maximum parallelization
make JOBS=8 iso    # Use 8 parallel jobs
```

## Output

Creates `l2e_boot/muinference.iso` (~50MB) containing:
- Linux kernel 6.5 with L2E module
- llama2.c with stories15M model (15M parameters)
- Minimal userspace (musl + busybox)

## License

- Linux kernel: GPL v2
- llama2.c: MIT
- Project: MIT

## Acknowledgments

- [llama2.c](https://github.com/karpathy/llama2.c) by Andrej Karpathy
- [L2E OS](https://github.com/trholding/llama2.c/) - Llama 2 Everywhere
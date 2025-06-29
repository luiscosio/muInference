# μInference

Research platform for micro inference server for SL5

## Overview

μInference creates a minimal bootable Linux ISO with embedded LLaMA model inference capabilities. It packages [llama2.c](https://github.com/karpathy/llama2.c) into a custom Linux distribution that boots directly into an inference environment.

## Features

- **Minimal Linux OS** - Custom kernel build with only essential components
- **Embedded LLaMA Model** - Includes stories15M model (15M parameters)
- **Instant Inference** - Boot directly into LLM inference environment
- **UEFI/BIOS Support** - Hybrid boot support for modern and legacy systems
- **Tiny Footprint** - Optimized for edge deployment

## Prerequisites

### Linux / WSL2
- Git
- GCC/Make
- wget/curl
- xorriso
- flex, bison, bc
- libelf-dev, libssl-dev

### Windows 11
Install WSL2 and Ubuntu:
```powershell
# Run in PowerShell as Administrator
wsl --install
```

Then install dependencies in WSL2:
```bash
sudo apt update
sudo apt install -y build-essential gcc make git wget curl xorriso \
    flex bison bc libelf-dev libssl-dev qemu-system-x86
```

## Quick Start

1. Clone the repository:
```bash
git clone https://github.com/luiscosio/muinference
cd muinference
```

2. Build the ISO:
```bash
make iso
```

This will:
- Clone and build llama2.c
- Download the stories15M model
- Build a custom Linux kernel
- Package everything into a bootable ISO

3. Test in QEMU (optional):
```bash
make boot_iso
```

## Output

The build process creates `l2e_boot/muinference.iso` - a bootable ISO image containing:
- Custom Linux kernel with L2E module
- llama2.c inference engine
- stories15M model
- Basic userspace utilities

## Usage

### Virtual Machine
- Use VirtualBox, VMware, or QEMU to boot the ISO
- Allocate at least 512MB RAM

### Physical Hardware
- Burn ISO to USB drive using Rufus (Windows) or dd (Linux)
- Boot from USB on x86_64 hardware

### In the booted system
The system will boot into a minimal Linux environment with the LLaMA inference engine ready to run.

## Build Targets

```bash
make help          # Show all targets
make iso           # Build complete ISO (default)
make boot_iso      # Test ISO in QEMU
make clean         # Clean build artifacts
make distclean     # Remove all downloaded sources
```

## Architecture

```
μInference ISO
├── Linux Kernel (v6.5)
│   └── L2E Module (inference integration)
├── Userspace
│   ├── musl libc (minimal C library)
│   ├── toybox (basic utilities)
│   └── llama2.c
│       ├── run (inference engine)
│       └── stories15M.bin (model)
└── Bootloader (Limine)
```

## Customization

To use a different model:
1. Modify `MODEL_URL` in the Makefile
2. Adjust kernel parameters if needed for larger models
3. Rebuild with `make clean && make iso`

## CI/CD

The included GitHub Action automatically builds and releases the ISO on every push to main:
- Place `.github/workflows/build-iso.yml` in your repository
- Each commit triggers a new release with the ISO attached

## Performance

- Boot time: ~10-30 seconds (depending on hardware)
- Inference speed: ~110 tokens/s on modern CPUs
- ISO size: ~500MB (including kernel and model)

## Troubleshooting

### Build fails on "xorriso not found"
Install xorriso: `sudo apt install xorriso`

### Out of memory during kernel compilation
The kernel build requires ~4GB RAM. Close other applications or increase swap.

### ISO won't boot
- Verify UEFI/Legacy boot settings match your hardware
- Try both boot modes if available
- Check that virtualization is enabled for VM testing

## Contributing

This is a research POC - keep modifications simple and focused on the core inference use case.

## License

Components under their respective licenses:
- Linux kernel: GPL v2
- llama2.c: MIT
- musl libc: MIT
- toybox: 0BSD

## Acknowledgments

- [llama2.c](https://github.com/karpathy/llama2.c) by Andrej Karpathy
- L2E boot sources for kernel integration
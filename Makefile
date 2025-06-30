# Minimal Makefile for μInference ISO

# Paths
LLAMA2C_REPO = https://github.com/karpathy/llama2.c
LLAMA2C_DIR = llama2c
MODEL_URL = https://huggingface.co/karpathy/tinyllamas/resolve/main/stories15M.bin

# Default target
.DEFAULT_GOAL = help

##@ Main Targets

.PHONY: iso
iso: build_llama2c l2e_os l2e_os_iso ##		- Build the complete bootable ISO

##@ Build Steps

.PHONY: build_llama2c
build_llama2c: ##		- Clone and build llama2.c
	@if [ ! -d "$(LLAMA2C_DIR)" ]; then \
		echo "Cloning llama2.c repository..."; \
		git clone --depth 1 $(LLAMA2C_REPO) $(LLAMA2C_DIR); \
	fi
	@echo "Building llama2.c..."
	cd $(LLAMA2C_DIR) && make runfast
	@echo "Downloading model..."
	cd $(LLAMA2C_DIR) && \
		if [ ! -f "stories15M.bin" ]; then \
			wget $(MODEL_URL); \
		fi

.PHONY: l2e_os
l2e_os: build_llama2c ##		- Build L2E OS components
	# Clone Linux kernel if needed
	@if [ ! -d "l2e_boot/linux" ]; then \
		echo "Cloning linux v6.5 sources..."; \
		git clone -b v6.5 --depth 1 https://github.com/torvalds/linux.git l2e_boot/linux; \
	fi
	
	# Clone musl if needed
	@if [ ! -d "l2e_boot/musl" ]; then \
		echo "Cloning musl v1.2.4 sources..."; \
		git clone -b v1.2.4 --depth 1 git://git.musl-libc.org/musl l2e_boot/musl; \
	fi
	
	# Build musl FIRST (before busybox needs it)
	@if [ ! -d "l2e_boot/musl_build" ]; then \
		cd l2e_boot/musl && \
		./configure --disable-shared --prefix=../musl_build --syslibdir=../musl_build/lib && \
		make -j$$(nproc) && \
		make install && \
		cd ../musl_build && \
		sed -i "s@../musl_build@$$(pwd)@g" bin/musl-gcc && \
		sed -i "s@../musl_build@$$(pwd)@g" lib/musl-gcc.specs && \
		cd ../linux && \
		make headers_install INSTALL_HDR_PATH=../kernel_headers && \
		cp -r ../kernel_headers/include/linux ../musl_build/include/ && \
		cp -r ../kernel_headers/include/asm ../musl_build/include/ && \
		cp -r ../kernel_headers/include/asm-generic ../musl_build/include/ && \
		cp -r ../kernel_headers/include/mtd ../musl_build/include/; \
	fi
	
	# Copy L2E sources to kernel FIRST (so directories exist for busybox)
	mkdir -p l2e_boot/linux/l2e
	mkdir -p l2e_boot/linux/drivers/misc
	cp -R l2e_boot/l2e_sources/l2e l2e_boot/linux/
	cp -R l2e_boot/l2e_sources/l2e_os l2e_boot/linux/drivers/misc/
	cp l2e_boot/l2e_sources/Kconfig l2e_boot/linux/drivers/misc/
	cp l2e_boot/l2e_sources/Makefile l2e_boot/linux/drivers/misc/
	cp l2e_boot/l2e_sources/L2E.gcc.config l2e_boot/linux/.config
	
	# Clone busybox for basic utilities
	@if [ ! -d "l2e_boot/busybox" ]; then \
		echo "Cloning busybox 1.37.0 sources..."; \
		git clone --depth 1 -b 1_37_0 git://busybox.net/busybox.git l2e_boot/busybox; \
	fi
	
	# Build busybox (now musl-gcc is available and l2e directory exists)
	@if [ ! -f "l2e_boot/linux/l2e/busybox" ]; then \
		cd l2e_boot/busybox && \
		cp ../l2e_sources/L2E.busybox.config .config && \
		make -j$$(nproc) CC=../musl_build/bin/musl-gcc CFLAGS="-static" && \
		cp busybox ../linux/l2e/; \
	fi
	
	# Clone limine bootloader
	@if [ ! -d "l2e_boot/limine" ]; then \
		echo "Downloading limine bootloader..."; \
		mkdir -p l2e_boot/limine; \
		curl -L https://github.com/limine-bootloader/limine/releases/download/v5.20230830.0/limine-5.20230830.0.tar.xz | tar -xJf - -C l2e_boot/limine --strip-components 1; \
	fi
	
	# Copy llama2.c files to kernel
	mkdir -p l2e_boot/linux/l2e/llama2c
	cp $(LLAMA2C_DIR)/run l2e_boot/linux/l2e/llama2c/
	cp $(LLAMA2C_DIR)/runq l2e_boot/linux/l2e/llama2c/
	cp $(LLAMA2C_DIR)/stories15M.bin l2e_boot/linux/l2e/llama2c/
	cp $(LLAMA2C_DIR)/tokenizer.bin l2e_boot/linux/l2e/llama2c/
	
	# Copy source and create symlinks for the kernel module build
	cp $(LLAMA2C_DIR)/run.c l2e_boot/linux/l2e/
	cp $(LLAMA2C_DIR)/stories15M.bin l2e_boot/linux/l2e/model.bin
	cp $(LLAMA2C_DIR)/tokenizer.bin l2e_boot/linux/l2e/tokenizer.bin
	
	# Build limine
	@if [ ! -d "l2e_boot/limine/bin" ]; then \
		cd l2e_boot/limine && \
		./configure --enable-bios-cd --enable-bios --enable-uefi-x86-64 --enable-uefi-cd && \
		make -j$$(nproc) && \
		rm -rf ../ISO && \
		cp -R ../l2e_sources/ISO ../ && \
		mkdir -p ../ISO/EFI/BOOT && \
		cp bin/limine-bios-cd.bin ../ISO/ && \
		cp bin/limine-bios.sys ../ISO/ && \
		cp bin/limine-uefi-cd.bin ../ISO/ && \
		cp bin/BOOTX64.EFI ../ISO/EFI/BOOT/; \
	fi

	# Build l2e userspace binaries BEFORE kernel build
	cd l2e_boot/linux/l2e && make l2e_bin_cc

	# Build kernel
	cd l2e_boot/linux && make V=1 -j1 LOCALVERSION="-μInference"
	cp l2e_boot/linux/arch/x86/boot/bzImage l2e_boot/ISO/L2E_Exec

.PHONY: l2e_os_iso
l2e_os_iso: ##		- Create bootable ISO image
	@if [ -d 'l2e_boot/ISO' ]; then \
		cd l2e_boot/ && \
		rm -f *.iso && \
		xorriso -volume_date uuid '2023100200000000' \
			-volid "μInference" \
			-publisher "μInference" \
			-as mkisofs -b /limine-bios-cd.bin \
			-no-emul-boot -boot-load-size 4 -boot-info-table \
			--efi-boot /limine-uefi-cd.bin \
			-efi-boot-part --efi-boot-image --protective-msdos-label \
			./ISO -o muinference.iso && \
		./limine/bin/limine bios-install muinference.iso; \
	fi

##@ Testing

.PHONY: boot_iso
boot_iso: ##		- Boot ISO in QEMU
	qemu-system-x86_64 -m 512M -cdrom l2e_boot/muinference.iso

##@ Cleanup

.PHONY: clean
clean: ##		- Clean build artifacts
	@if [ -d "$(LLAMA2C_DIR)" ]; then cd $(LLAMA2C_DIR) && make clean; fi
	@if [ -d "l2e_boot/linux" ]; then cd l2e_boot/linux && make clean; fi
	@if [ -d "l2e_boot/busybox" ]; then cd l2e_boot/busybox && make clean; fi
	@if [ -d "l2e_boot/musl" ]; then cd l2e_boot/musl && make clean; fi
	@if [ -d "l2e_boot/limine" ]; then cd l2e_boot/limine && make clean; fi
	rm -f l2e_boot/*.iso

.PHONY: distclean
distclean: clean ##		- Deep clean (remove downloaded sources)
	rm -rf $(LLAMA2C_DIR)
	rm -rf l2e_boot/linux
	rm -rf l2e_boot/musl
	rm -rf l2e_boot/musl_build
	rm -rf l2e_boot/kernel_headers
	rm -rf l2e_boot/busybox
	rm -rf l2e_boot/limine
	rm -rf l2e_boot/ISO

##@ Help

.PHONY: help
help: ##		- Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)
# muinference core -- build and determinism harness
#
# DETERMINISM FLAGS (do not change without reading mu_math.h)
#   -fno-fast-math                 forbid reassociation of FP expressions
#   -ffp-contract=off              forbid fusing a*b+c into FMA (rounds once,
#                                  not twice, so it changes results)
#   -fno-unsafe-math-optimizations belt and braces
#   no -march=native               machine-independent codegen
#   no -ffast-math, no -fopenmp    the two things upstream's Makefile uses
#
# The baseline ISA is pinned explicitly per architecture so that the compiler
# cannot select a wider vector width on a newer host and change the partial-sum
# tree. That is the mechanism behind cross-machine divergence in ggml.

ROOT      := $(abspath $(dir $(abspath $(lastword $(MAKEFILE_LIST))))..)

# `CC ?= clang` does NOT work here: make has a built-in default of CC=cc, and
# ?= treats a built-in as already set, so the assignment is a silent no-op. On
# macOS cc happens to be clang so it looked fine; on Linux CI it resolved to
# gcc. Testing $(origin) is the correct idiom: override the built-in default
# but still respect a CC the caller set deliberately.
ifeq ($(origin CC),default)
  CC := clang
endif

DETFLAGS  := -fno-fast-math -ffp-contract=off -fno-unsafe-math-optimizations
WARN      := -Wall -Wextra -Wno-unused-parameter
CFLAGS    := -std=c11 -O2 $(DETFLAGS) $(WARN) -I$(ROOT)/mucore

UNAME_M   := $(shell uname -m)
ifeq ($(UNAME_M),arm64)
  ISAFLAGS := -march=armv8-a
endif
ifeq ($(UNAME_M),aarch64)
  ISAFLAGS := -march=armv8-a
endif
ifeq ($(UNAME_M),x86_64)
  ISAFLAGS := -march=x86-64-v2
endif

CORE      := $(ROOT)/mucore/mu_core.c
HOST      := $(ROOT)/mucore/hosts/posix/main.c
BUILD     := $(ROOT)/mucore/build

MODEL     := $(ROOT)/model/stories15M.bin
TOKENIZER := $(ROOT)/model/tokenizer.bin
ROPE      := $(ROOT)/mucore/tables/rope_256x48.bin

.PHONY: all clean rope verify-rope test test-determinism test-parity ref variants \
        verify verify-s1 verify-s3a verify-s4a

all: $(BUILD)/mu

# Convenience aliases so the variants can be built by short name.
variants: $(BUILD)/mu $(BUILD)/mu_o0 $(BUILD)/mu_o3 $(BUILD)/mu_os $(BUILD)/mu_ofast \
          $(BUILD)/mu_altcc

# A second, genuinely independent compiler: different frontend, different
# optimiser, different code generator. Clang-vs-clang across versions is a weak
# check; clang-vs-gcc is a real one. Skipped rather than failed when absent, so
# the build still works on a machine with only one compiler.
ALTCC := $(firstword $(foreach c,gcc-16 gcc-15 gcc-14 gcc-13 gcc, \
           $(if $(shell command -v $(c) 2>/dev/null),$(c))))

$(BUILD):
	@mkdir -p $(BUILD)

# Primary artifact.
$(BUILD)/mu: $(CORE) $(HOST) | $(BUILD)
	$(CC) $(CFLAGS) $(ISAFLAGS) -o $@ $(CORE) $(HOST)

# Variants used only to prove the output does not depend on how it was built.
$(BUILD)/mu_o0: $(CORE) $(HOST) | $(BUILD)
	$(CC) -std=c11 -O0 $(DETFLAGS) -I$(ROOT)/mucore $(ISAFLAGS) -o $@ $(CORE) $(HOST)

$(BUILD)/mu_o3: $(CORE) $(HOST) | $(BUILD)
	$(CC) -std=c11 -O3 $(DETFLAGS) -I$(ROOT)/mucore $(ISAFLAGS) -o $@ $(CORE) $(HOST)

$(BUILD)/mu_os: $(CORE) $(HOST) | $(BUILD)
	$(CC) -std=c11 -Os $(DETFLAGS) -I$(ROOT)/mucore $(ISAFLAGS) -o $@ $(CORE) $(HOST)

# Deliberately WRONG build: what upstream's Makefile does. Kept as a negative
# control, because a determinism claim is only interesting if the test can fail.
$(BUILD)/mu_ofast: $(CORE) $(HOST) | $(BUILD)
	$(CC) -std=c11 -Ofast -I$(ROOT)/mucore -march=native -o $@ $(CORE) $(HOST)

$(BUILD)/mu_altcc: $(CORE) $(HOST) | $(BUILD)
ifeq ($(ALTCC),)
	@echo "  no second compiler found (gcc); skipping mu_altcc"
else
	$(ALTCC) -std=c11 -O2 $(DETFLAGS) -I$(ROOT)/mucore $(ISAFLAGS) -o $@ $(CORE) $(HOST)
endif

# Reference upstream binary, built the same careful way, for parity checks.
#
# Two concessions are needed to compile upstream run.c unmodified, and it is
# kept byte-identical to upstream deliberately: patching the oracle would
# undermine the point of having one.
#
#   -std=gnu11        run.c calls clock_gettime and uses CLOCK_REALTIME. On
#                     glibc, -std=c11 is strict ISO mode, which switches off
#                     _DEFAULT_SOURCE and hides every POSIX declaration. Apple
#                     libc is more permissive, which is why this only failed on
#                     Linux. gnu11 changes no floating point semantics.
#   -include stdint.h run.c uses int8_t without including <stdint.h> and relies
#                     on it arriving transitively, which glibc does not do.
#
# The FP flags are identical to ours, so the parity comparison still isolates
# the arithmetic rather than the build.
ref: $(BUILD)/run_ref
$(BUILD)/run_ref: $(ROOT)/vendor/llama2c/run.c | $(BUILD)
	$(CC) -std=gnu11 -O2 $(DETFLAGS) -include stdint.h \
	  -o $@ $(ROOT)/vendor/llama2c/run.c -lm

rope:
	python3 $(ROOT)/mucore/tools/gen_rope.py --seq-len 256 --head-size 48 \
		-o $(ROPE)

verify-rope:
	@cd $(ROOT)/mucore/tables && shasum -a 256 -c rope_256x48.bin.sha256

MUARGS := -m $(MODEL) -z $(TOKENIZER) -r $(ROPE)

test: verify-rope test-determinism

test-determinism: $(BUILD)/mu $(BUILD)/mu_o0 $(BUILD)/mu_o3 $(BUILD)/mu_os
	@bash $(ROOT)/mucore/tests/determinism.sh

test-parity: $(BUILD)/mu $(BUILD)/run_ref
	@bash $(ROOT)/mucore/tests/parity.sh

# ---------------------------------------------------------------------------
# Formal verification. Clause status is tracked in ../SPEC.md; nothing is
# claimed there until it is green here.
#
#   verify-s1   CBMC: no undefined behaviour, arena bounds (S1 partial, S2)
#   verify-s3a  static check that only exactly-rounded FP ops are emitted (S3a)
#   verify-s4a  exhaustive check of mu_expf over all 2^32 inputs (S4a)
# ---------------------------------------------------------------------------
verify:
	@bash $(ROOT)/mucore/tests/verify.sh

CBMC_CHECKS := --bounds-check --pointer-check --pointer-overflow-check \
               --div-by-zero-check --conversion-check \
               --signed-overflow-check --unsigned-overflow-check \
               --unwinding-assertions --no-standard-checks

verify-s1:
	@bash $(ROOT)/mucore/tests/verify.sh

verify-s3a:
	@bash $(ROOT)/mucore/tests/check_s3a.sh

$(BUILD)/exhaustive_expf: $(ROOT)/mucore/tests/exhaustive_expf.c $(ROOT)/mucore/mu_math.h | $(BUILD)
	$(CC) -std=c11 -O2 $(DETFLAGS) -I$(ROOT)/mucore -pthread -o $@ $< -lm

verify-s4a: $(BUILD)/exhaustive_expf
	@$(BUILD)/exhaustive_expf

# ---------------------------------------------------------------------------
# Stage B: freestanding aarch64 bare metal, run under QEMU.
#
# Same mu_core.c, different compiler driver, different linker, no libc, no OS.
# The blobs are objcopy'd into the image so one hash covers weights and code
# together, as a Microkit image would. Output leaves via ARM semihosting.
# ---------------------------------------------------------------------------
# Cross toolchain. Homebrew keeps llvm and lld out of PATH by default on macOS,
# so prefer those prefixes when they exist and otherwise fall back to PATH,
# which is what a Linux CI runner has.
BREW_LLVM := /opt/homebrew/opt/llvm/bin
BREW_LLD  := /opt/homebrew/opt/lld/bin

BMCC      := $(if $(wildcard $(BREW_LLVM)/clang),$(BREW_LLVM)/clang,clang)
OBJCOPY   := $(if $(wildcard $(BREW_LLVM)/llvm-objcopy),$(BREW_LLVM)/llvm-objcopy,llvm-objcopy)
LD        := $(if $(wildcard $(BREW_LLD)/ld.lld),$(BREW_LLD)/ld.lld,ld.lld)
BM        := $(BUILD)/bm

BMTARGET  := --target=aarch64-none-elf
BMFLAGS   := $(BMTARGET) -ffreestanding -fno-builtin -fno-pic -fno-stack-protector \
             -march=armv8-a -std=c11 -O2 $(DETFLAGS) $(WARN) -I$(ROOT)/mucore
BMSTEPS   ?= 24

.PHONY: baremetal bm-run bm-verify

$(BM):
	@mkdir -p $(BM)

# Blob -> relocatable object.
#
# objcopy derives the _binary_<name>_start symbol from the input path, mangling
# every non-alphanumeric character to an underscore. Passing an absolute path
# therefore bakes the checkout location into the symbol names, and into the
# resulting image. That is both a link error waiting to happen and a textbook
# reproducible-build defect: two developers with different home directories
# would produce different artifacts from identical sources.
#
# So we cd into the blob directory and pass a bare filename. The image is then
# independent of where the repository lives.
$(BM)/model.bin: $(MODEL) | $(BM)
	cp $< $@
$(BM)/tokenizer.bin: $(TOKENIZER) | $(BM)
	cp $< $@
$(BM)/rope.bin: $(ROPE) | $(BM)
	cp $< $@

define BLOBRULE
$(BM)/$(1).o: $(BM)/$(1).bin
	cd $$(BM) && $$(OBJCOPY) -I binary -O elf64-littleaarch64 \
	  --rename-section .data=.rodata_blobs,alloc,load,readonly,data,contents \
	  $(1).bin $(1).o
endef
$(eval $(call BLOBRULE,model))
$(eval $(call BLOBRULE,tokenizer))
$(eval $(call BLOBRULE,rope))

$(BM)/mu_core.o: $(CORE) | $(BM)
	$(BMCC) $(BMFLAGS) -c $< -o $@

$(BM)/bm_main.o: $(ROOT)/mucore/hosts/baremetal/main.c | $(BM)
	$(BMCC) $(BMFLAGS) -DMU_BM_STEPS=$(BMSTEPS) -c $< -o $@

$(BM)/start.o: $(ROOT)/mucore/hosts/baremetal/start.S | $(BM)
	$(BMCC) $(BMTARGET) -c $< -o $@

$(BM)/mu_bm.elf: $(BM)/start.o $(BM)/mu_core.o $(BM)/bm_main.o \
                 $(BM)/model.o $(BM)/tokenizer.o $(BM)/rope.o \
                 $(ROOT)/mucore/hosts/baremetal/link.ld
	$(LD) -T $(ROOT)/mucore/hosts/baremetal/link.ld --no-dynamic-linker \
	  -o $@ $(BM)/start.o $(BM)/mu_core.o $(BM)/bm_main.o \
	  $(BM)/model.o $(BM)/tokenizer.o $(BM)/rope.o

baremetal: $(BM)/mu_bm.elf

# macOS has no coreutils timeout; perl's alarm is always present.
QEMU_CAP ?= 300
bm-run: $(BM)/mu_bm.elf
	cd $(BM) && rm -f bm.logits && \
	perl -e 'alarm shift; exec @ARGV' $(QEMU_CAP) \
	  qemu-system-aarch64 -machine virt -cpu cortex-a57 -m 512M -nographic \
	  -semihosting-config enable=on,target=native -kernel mu_bm.elf

# The headline test: does a freestanding aarch64 image running on emulated
# hardware produce the same bits as a hosted macOS build?
bm-verify: bm-run $(BUILD)/mu
	@bash $(ROOT)/mucore/tests/cross_env.sh

# ---------------------------------------------------------------------------
# Stage B2: freestanding x86-64 multiboot, run under QEMU.
#
# Closes the cross-ISA gap. Different LLVM backend (SSE, not NEON), and QEMU's
# x86 TCG evaluates SSE through its own softfloat library rather than on the
# host FPU -- so this is a genuinely independent floating point implementation,
# not another view of the same silicon.
#
# COM1 carries progress text, COM2 carries raw float32 logits to a file.
# ---------------------------------------------------------------------------
X86       := $(BUILD)/x86
X86TARGET := --target=x86_64-elf
X86FLAGS  := $(X86TARGET) -ffreestanding -fno-builtin -fno-pic -fno-stack-protector \
             -mno-red-zone -march=x86-64-v2 -std=c11 -O2 $(DETFLAGS) $(WARN) \
             -I$(ROOT)/mucore

.PHONY: x86 x86-run x86-verify

$(X86):
	@mkdir -p $(X86)

$(X86)/model.bin: $(MODEL) | $(X86)
	cp $< $@
$(X86)/tokenizer.bin: $(TOKENIZER) | $(X86)
	cp $< $@
$(X86)/rope.bin: $(ROPE) | $(X86)
	cp $< $@

# Same bare-filename discipline as the aarch64 blobs: keeps the checkout path
# out of the symbol names and out of the image.
define X86BLOB
$(X86)/$(1).o: $(X86)/$(1).bin
	cd $$(X86) && $$(OBJCOPY) -I binary -O elf64-x86-64 \
	  --rename-section .data=.rodata_blobs,alloc,load,readonly,data,contents \
	  $(1).bin $(1).o
endef
$(eval $(call X86BLOB,model))
$(eval $(call X86BLOB,tokenizer))
$(eval $(call X86BLOB,rope))

$(X86)/mu_core.o: $(CORE) | $(X86)
	$(BMCC) $(X86FLAGS) -c $< -o $@

$(X86)/x86_main.o: $(ROOT)/mucore/hosts/x86_64/main.c | $(X86)
	$(BMCC) $(X86FLAGS) -DMU_BM_STEPS=$(BMSTEPS) -c $< -o $@

$(X86)/boot.o: $(ROOT)/mucore/hosts/x86_64/boot.S | $(X86)
	$(BMCC) $(X86TARGET) -c $< -o $@

$(X86)/mu_x86.elf: $(X86)/boot.o $(X86)/mu_core.o $(X86)/x86_main.o \
                   $(X86)/model.o $(X86)/tokenizer.o $(X86)/rope.o \
                   $(ROOT)/mucore/hosts/x86_64/link.ld
	$(LD) -T $(ROOT)/mucore/hosts/x86_64/link.ld --no-dynamic-linker \
	  -o $@ $(X86)/boot.o $(X86)/mu_core.o $(X86)/x86_main.o \
	  $(X86)/model.o $(X86)/tokenizer.o $(X86)/rope.o

x86: $(X86)/mu_x86.elf

# -cpu Nehalem, not the default qemu64.
#
# We compile with -march=x86-64-v2, the same baseline a native x86 build would
# pin, and v2 includes SSE4.1/SSE4.2/POPCNT. QEMU's default qemu64 CPU does not
# implement those, so clang's `pminud` raises #UD, which with no IDT becomes a
# triple fault and a silent reset. Nehalem is the earliest model that provides
# the full v2 feature set. Named explicitly rather than using -cpu max so the
# test does not drift with the QEMU version.
X86CPU ?= Nehalem

x86-run: $(X86)/mu_x86.elf
	cd $(X86) && rm -f x86.logits && \
	perl -e 'alarm shift; exec @ARGV' $(QEMU_CAP) \
	  qemu-system-x86_64 -m 512M -cpu $(X86CPU) -nographic -no-reboot \
	  -device isa-debug-exit \
	  -serial mon:stdio -serial file:x86.logits \
	  -kernel mu_x86.elf || true

x86-verify: x86-run $(BUILD)/mu
	@bash $(ROOT)/mucore/tests/cross_env.sh

# ---------------------------------------------------------------------------
# Stage C: seL4 / Microkit protection domain, aarch64, single core.
#
# The target configuration. One PD, no channels, no device access, no Linux.
# Blobs are linked into the PD image, so one hash covers code and weights.
#
# Needs the SDK: vendor/microkit/fetch.sh
# ---------------------------------------------------------------------------
MK_SDK    ?= $(ROOT)/vendor/microkit/microkit-sdk-2.3.0
MK_BOARD  ?= qemu_virt_aarch64
MK_CONFIG ?= debug
MK_DIR    := $(MK_SDK)/board/$(MK_BOARD)/$(MK_CONFIG)
MK_TOOL   := $(MK_SDK)/bin/microkit
MK        := $(BUILD)/mk
MK_STEPS  ?= 24

# -mstrict-align matches the SDK examples: seL4 PDs must not rely on unaligned
# access. The core was written for this (the tokenizer does byte-wise loads).
MKBASE    := --target=aarch64-none-elf -nostdlib -ffreestanding -mstrict-align \
             -march=armv8-a -O2 $(DETFLAGS) $(WARN) -I$(ROOT)/mucore

# The core is built as strict C11 here as everywhere else, which is worth
# keeping: it demonstrates the core needs no GNU extensions and no seL4 headers.
MKFLAGS   := $(MKBASE) -std=c11

# The PD host needs -std=gnu11 because seL4's syscall headers use the GNU
# `register seL4_Word x asm("x3")` extension, which strict C11 rejects.
MKPDFLAGS := $(MKBASE) -std=gnu11 -I$(MK_DIR)/include

.PHONY: microkit mk-run mk-verify sdk

sdk:
	@bash $(ROOT)/vendor/microkit/fetch.sh

$(MK):
	@mkdir -p $(MK)

$(MK)/model.bin: $(MODEL) | $(MK)
	cp $< $@
$(MK)/tokenizer.bin: $(TOKENIZER) | $(MK)
	cp $< $@
$(MK)/rope.bin: $(ROPE) | $(MK)
	cp $< $@

# Section name is exactly `.rodata`, not a custom name: microkit.ld matches
# only `*(.rodata)` for read-only input, so anything else becomes an orphan
# section placed wherever the linker feels like. Alignment is forced to 64 so
# the float arrays inside are safely aligned under -mstrict-align.
define MKBLOB
$(MK)/$(1).o: $(MK)/$(1).bin
	cd $$(MK) && $$(OBJCOPY) -I binary -O elf64-littleaarch64 \
	  --rename-section .data=.rodata,alloc,load,readonly,data,contents \
	  --set-section-alignment .rodata=64 \
	  $(1).bin $(1).o
endef
$(eval $(call MKBLOB,model))
$(eval $(call MKBLOB,tokenizer))
$(eval $(call MKBLOB,rope))

$(MK)/mu_core.o: $(CORE) | $(MK)
	$(BMCC) $(MKFLAGS) -c $< -o $@

$(MK)/mu_pd.o: $(ROOT)/mucore/hosts/microkit/mu_pd.c | $(MK)
	$(BMCC) $(MKPDFLAGS) -DMU_MK_STEPS=$(MK_STEPS) -c $< -o $@

$(MK)/mu_pd.elf: $(MK)/mu_pd.o $(MK)/mu_core.o \
                 $(MK)/model.o $(MK)/tokenizer.o $(MK)/rope.o
	$(LD) -L$(MK_DIR)/lib $^ -lmicrokit -Tmicrokit.ld -o $@

$(MK)/loader.img: $(MK)/mu_pd.elf $(ROOT)/mucore/hosts/microkit/mu.system
	$(MK_TOOL) $(ROOT)/mucore/hosts/microkit/mu.system \
	  --search-path $(MK) --board $(MK_BOARD) --config $(MK_CONFIG) \
	  -o $@ -r $(MK)/report.txt

microkit: $(MK)/loader.img

# virtualization=on is required: the qemu_virt_aarch64 board expects to boot at
# EL2 ("seL4 configured as hypervisor"). The qemu_virt_aarch64_el1 board variant
# is the one that boots at EL1.
#
# sed quits at the end marker, which closes the pipe and takes QEMU with it.
# aarch64 virt has no isa-debug-exit equivalent, so this is the clean way to
# stop as soon as the payload is complete.
#
# The cap is generous because the PD's only output channel is seL4's debug
# console: one seL4_DebugPutChar syscall per hex nibble, so 24 steps is 6.1M
# syscalls under TCG, on top of copying an 80 MiB initial task.
MK_CAP ?= 1500
mk-run: $(MK)/loader.img
	cd $(MK) && rm -f mk.out && \
	((perl -e 'alarm shift; exec @ARGV' $(MK_CAP) \
	  qemu-system-aarch64 -machine virt,virtualization=on -cpu cortex-a53 \
	  -m 2048M -nographic \
	  -device loader,file=loader.img,addr=0x70000000,cpu-num=0 2>&1 \
	  || true) | sed '/@@@END/q' > mk.out); \
	echo "captured $$(wc -c < mk.out) bytes"

mk-verify: mk-run $(BUILD)/mu
	@bash $(ROOT)/mucore/tests/mk_verify.sh

clean:
	rm -rf $(BUILD)

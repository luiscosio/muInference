# mucore — a bit-reproducible, freestanding LLM inference core

Output is a pure function of its inputs, provably independent of compiler,
optimisation level, C library, linker, instruction set, floating point
implementation, operating system, and kernel.

Derived from [llama2.c](https://github.com/karpathy/llama2.c) (MIT, Andrej
Karpathy). The arithmetic is faithful to the original. Everything else changed.

## Why

Verifying LLM inference by re-execution requires an engine that produces the
same bits twice. Production servers do not, and the reason is not floating point
noise: it is **batch-invariance failure**. Matmul, RMSNorm and attention change
their reduction strategy with batch shape, and batch shape depends on server
load. Making vLLM deterministic costs 1.6–2× throughput.

A single-stream engine has no batch-invariance problem to solve, so it gets
determinism for free. That is a consequence of the design, not a feature bolted
on.

Every scheme that checks an LLM's work needs a referee: TOPLOC needs "a trusted
party to re-run for ground truth", Gensyn's Verde needs a referee that
recomputes one operator, EigenAI's challenge path re-executes inside a TEE. None
of them has an engine small enough to be worth trusting more than the thing it
is checking.

## The determinism argument

IEEE-754 clause 5.4.1 **mandates** correct rounding for `+ − × ÷ √`. Two
conforming implementations must agree bit-for-bit. Clause 9.2 lists `exp`,
`log`, `sin`, `cos`, `pow` as *recommended only*, and real libm implementations
differ between vendors, versions, and even between the scalar and vectorised
paths of one library.

So the core uses nothing but mandated operations:

| Original | Here |
|---|---|
| `expf` (softmax, SwiGLU) | degree-7 Taylor with range reduction, binary64 internals, `2^k` assembled as a bit pattern. Only `+ − ×`. |
| `sqrtf` (RMSNorm) | hardware `fsqrt`, IEEE-754 mandated |
| `sqrtf(head_size)` | hoisted; it is a constant |
| `powf`, `cosf`, `sinf` (RoPE) | **removed from the runtime.** Precomputed offline into a measured table, pinned by SHA-256. |
| `malloc`/`calloc`/`mmap` | one caller-provided arena, no heap |
| `#pragma omp parallel for` | removed; parallel reduction reorders accumulation |
| temperature / top-p sampling | greedy `argmax` only, no RNG |

Two compiler flags are load-bearing and non-negotiable:

```
-fno-fast-math      forbids reassociating floating-point expressions
-ffp-contract=off   forbids fusing a*b+c into FMA, which rounds once
                    where the source rounds twice
```

`-march` is pinned to a baseline (`armv8-a` / `x86-64-v2`) rather than `native`,
so the compiler cannot pick a wider vector width on a newer host and change the
partial-sum tree.

## Results

Host: macOS 26.5.2, Apple Silicon. Reproduced from a clean build.

### Bit-exactness across seven environments

`bash tests/cross_env.sh`. Fingerprint is SHA-256 of the raw float32 logits for
every decode step (3,072,000 bytes: 24 steps × 32000 vocab × 4), hashed by
`shasum`, not by anything in this repo.

| Environment | libc | linker | FP implementation |
|---|---|---|---|
| macOS arm64, Apple clang 21, `-O2` | libSystem | ld64 | Apple Silicon FPU |
| macOS arm64, Apple clang 21, `-O0` | libSystem | ld64 | Apple Silicon FPU |
| macOS arm64, Homebrew clang 22, `-O2` | libSystem | ld64 | Apple Silicon FPU |
| **macOS arm64, GCC 16.1.0, `-O2`** | libSystem | ld64 | Apple Silicon FPU |
| aarch64-none-elf bare metal, QEMU cortex-a57 | **none** | ld.lld | Apple Silicon FPU |
| **x86-64 bare metal, QEMU Nehalem** | **none** | ld.lld | **QEMU softfloat SSE** |
| **seL4 / Microkit PD, aarch64, QEMU cortex-a53** | **none** | ld.lld | Apple Silicon FPU |

All seven: `9b78b92a305dc59611b5c53a04b538ae9c4ae18aea6c1fdbf6e45e9848b23bd2`

Two rows carry the most weight. **GCC** shares no frontend, optimiser or backend
with clang, so clang-vs-gcc agreement is a far stronger signal than clang-vs-clang
across versions. And the **x86-64** row is a different LLVM backend (SSE, not
NEON) executed by QEMU's own softfloat library: an independent floating point
*implementation*, not another view of the same silicon.

The seL4 row is the target configuration: one protection domain, no channels,
no memory regions, no IRQs, no device mappings. Its entire authority is its own
address space plus the debug console, which is why the logits come out as hex —
a PD with no device capabilities has no other channel.

### Determinism suite

`make test` — 7/7 pass.

1. Same binary, 5 consecutive runs, bit-identical.
2. `-O0` / `-O2` / `-O3` / `-Os` all bit-identical.
3. **Negative control:** `-Ofast -march=native` (what upstream's Makefile uses)
   produces a **different** hash, `351ebd7b…`. The suite is not vacuous, and
   upstream's flags demonstrably destroy reproducibility.
4. No libm linked.
5. No undefined `exp`/`pow`/`sin`/`cos`/`log` symbols.
6. No `malloc`/`calloc`/`realloc` referenced.
7. RoPE table matches its recorded SHA-256.

The mechanism behind (3) is visible in the object code: the correct build emits
**zero** `fmla`/`fmadd` instructions; `-Ofast -march=native` emits **96**.

### Accuracy

Determinism is worthless without accuracy — a reproducibly wrong `exp` would
pass every test above. `build/expf_acc` vs platform libm, 16M sample points:

| Range | bit-exact | ≤ 1 ULP | max error |
|---|---|---|---|
| `[-40, 0]` (softmax) | 98.87% | **100%** | 1 ULP |
| `[-30, 30]` (SwiGLU) | 98.87% | **100%** | 1 ULP |
| `[-87, 88]` (full) | 98.86% | **100%** | 1 ULP |

`exp(0) == 1.0` exactly. Never worse than 1 ULP anywhere tested.

### Parity with upstream

`make test-parity` — **5/5 prompts produce byte-identical text** to upstream
`run.c` at temperature 0, 160 steps, both built with the same careful FP flags.
The deterministic `expf` and the measured RoPE table do not change the model's
output on this checkpoint.

### Footprint

stories15M (dim 288, 6 layers, 6 heads, vocab 32000, seq_len 256):

- runtime trusted surface: **692 lines of code** (`mu_math.h` 85, `mu_core.h`
  133, `mu_core.c` 474), versus 973 raw lines for upstream `run.c`
- arena high-water mark: **4,131,840 bytes**, identical in every environment
- 24 steps under QEMU TCG: 1.9 s aarch64 bare metal, 9.1 s x86-64
- images: 61.4 MB aarch64, 61.3 MB x86-64, 86.8 MB Microkit `loader.img`
  (80.5 MiB initial task), each with the weights linked in

Hosts are swappable and not shared TCB: POSIX 159 lines, aarch64 bare metal 173
C + 165 asm, x86-64 182 C + 183 asm, Microkit PD 157 lines.

## Layout

```
mu_math.h              deterministic expf / sqrtf. Read this first.
mu_core.h              API. No libc types beyond stdint/stddef.
mu_core.c              transformer forward, arena, tokenizer, argmax
tables/rope_256x48.bin measured RoPE table + .sha256
tools/gen_rope.py      offline generator for the above
hosts/posix/           development and testing harness
hosts/baremetal/       freestanding aarch64, own MMU, semihosting
hosts/x86_64/          freestanding x86-64, PVH boot, dual serial
hosts/microkit/        seL4 protection domain + .system description
tests/                 determinism, cross-environment, parity, expf accuracy
```

Only `hosts/` differs between deployments. A determinism result measured in one
host carries over because the code under test is identical.

## Build

```sh
../model/fetch.sh                # hash-verified model inputs
../vendor/microkit/fetch.sh      # seL4 Microkit SDK (Stage C only)

make && make test                # engine + determinism suite
make test-parity                 # vs upstream llama2.c
make baremetal bm-run            # freestanding aarch64 under QEMU
make x86 x86-run                 # freestanding x86-64 under QEMU
make microkit mk-run             # seL4 / Microkit protection domain
bash tests/cross_env.sh          # the six-environment comparison
```

Needs `clang`; for freestanding and seL4 targets also `brew install qemu llvm lld`.

Three environment notes worth knowing, each learned the hard way and encoded in
the Makefile:

- **x86-64 needs `-cpu Nehalem`, not QEMU's default `qemu64`.** We compile
  `-march=x86-64-v2`, which includes SSE4.1; `qemu64` does not implement it, so
  clang's `pminud` raises #UD, which with no IDT is a triple fault and a silent
  reset.
- **x86-64 boots via PVH, not multiboot.** QEMU's multiboot loader rejects ELF64
  outright, and finding a multiboot header makes it commit to that path before
  PVH is considered. So there is deliberately no multiboot header.
- **Microkit needs `-machine virt,virtualization=on`.** The `qemu_virt_aarch64`
  board expects to boot at EL2; `qemu_virt_aarch64_el1` is the EL1 variant.

## On seL4's verification status, precisely

The AArch64 hypervisor configuration has machine-checked functional correctness
and integrity proofs. Stating the limits explicitly, because the value of this
project is the accuracy of its claims:

- Confidentiality is listed as in progress; information flow is not proven.
- Binary-level verification covers AArch32 and RISC-V64, not AArch64, so on
  AArch64 the compiler and linker are trusted.
- **No verified configuration on any architecture includes an IOMMU/SMMU.**
- Verified means **single core**. SMP is unverified on every architecture.
- The proofs exclude the compiler, linker, boot code, and cache/TLB management,
  and make no guarantees about timing channels.
- Every verified AArch64 platform is an embedded SoC. There is no verified seL4
  configuration for any server-class machine.

So the honest claim is: this runs on a formally verified microkernel, in a
configuration whose functional correctness and integrity are proven, as a single
protection domain with no device access. Not "formally verified isolation on
server hardware", which nobody can currently claim.

## What is NOT proven

- **QEMU only.** No run on real hardware. Emulation is a strong test of
  arithmetic portability and a weak test of everything else.
- **Reproducible *builds* are not claimed.** Bit-identical *output* from
  different builds and architectures is demonstrated. Byte-identical *binaries*
  from independent builders is a separate property and is not done.
- **One checkpoint, one size.** stories15M, 15M parameters, seq_len 256. Nothing
  here has been exercised at 7B, and `MU_MAX_*` bounds would need raising.
- **Greedy sampling only.** Temperature sampling needs a specified, seeded,
  reproducible PRNG. Not implemented, on purpose.
- **CPU only, deliberately.** A GPU reintroduces signed vendor firmware
  (GSP/PSP) that boots before your code and cannot be substituted, and on
  NVIDIA a closed kernel compiler. Both are unavoidable holes in any
  verifiability claim involving a modern discrete GPU. See
  `../documentation/design.md`.

## License

MIT, matching llama2.c. Attribution to Andrej Karpathy for the original.

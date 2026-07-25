# μInference

A small, auditable LLM inference engine whose output is a pure function of its
inputs — provably independent of compiler, optimisation level, C library,
linker, instruction set, floating point implementation, operating system, and
kernel.

Runs as a single seL4/Microkit protection domain on a formally verified
microkernel, with no Linux, no GPU, and no device access.

Derived from [llama2.c](https://github.com/karpathy/llama2.c) (MIT, Andrej
Karpathy). The arithmetic is faithful to the original.

## The result

One `mu_core.c`, six environments, **identical logits down to the bit**.
Fingerprint is SHA-256 over the raw float32 logits of every decode step
(3,072,000 bytes: 24 steps × 32000 vocab × 4), hashed by `shasum`.

| Environment | libc | linker | FP implementation |
|---|---|---|---|
| macOS arm64, Apple clang 21, `-O2` | libSystem | ld64 | Apple Silicon FPU |
| macOS arm64, Apple clang 21, `-O0` | libSystem | ld64 | Apple Silicon FPU |
| macOS arm64, Homebrew clang 22, `-O2` | libSystem | ld64 | Apple Silicon FPU |
| aarch64-none-elf bare metal, QEMU | **none** | ld.lld | Apple Silicon FPU |
| **x86-64 bare metal, QEMU** | **none** | ld.lld | **QEMU softfloat SSE** |
| **seL4 / Microkit PD, aarch64** | **none** | ld.lld | Apple Silicon FPU |

```
9b78b92a305dc59611b5c53a04b538ae9c4ae18aea6c1fdbf6e45e9848b23bd2
```

The x86-64 row matters most: a different LLVM backend (SSE, not NEON) executed
by QEMU's own softfloat library. That makes it an independent floating point
*implementation*, not another view of the same silicon.

## Why

Verifying LLM inference by re-execution needs an engine that produces the same
bits twice. Production servers do not. Nondeterminism there is not floating
point noise, it is **batch-invariance failure**: matmul, RMSNorm and attention
change reduction strategy with batch shape, and batch shape depends on server
load. Making vLLM deterministic costs 1.6–2× throughput.

A single-stream engine has no batch-invariance problem to solve, so it gets
determinism for free.

Every scheme that checks an LLM's work needs a referee it can trust more than
the thing being checked, and none of them has one. That is the gap here.

## How

IEEE-754 clause 5.4.1 **mandates** correct rounding for `+ − × ÷ √`. Clause 9.2
lists `exp`, `log`, `sin`, `cos`, `pow` as *recommended only*, which is why libm
results differ between vendors, versions, and even between the scalar and
vectorised paths of one library.

So the core uses nothing but mandated operations:

| Original | Here |
|---|---|
| `expf` (softmax, SwiGLU) | degree-7 Taylor, range reduction, `2^k` as a bit pattern. Only `+ − ×`. Within **1 ULP** of libm everywhere tested. |
| `sqrtf` (RMSNorm) | hardware `fsqrt`, IEEE-754 mandated |
| `powf`/`cosf`/`sinf` (RoPE) | **removed from the runtime.** Precomputed offline into a measured table, pinned by SHA-256. |
| `malloc`/`calloc`/`mmap` | one static arena, no heap |
| `#pragma omp parallel for` | removed; parallel reduction reorders accumulation |
| temperature / top-p sampling | greedy `argmax`, no RNG |

Two compiler flags are load-bearing: `-fno-fast-math` (forbids reassociation)
and `-ffp-contract=off` (forbids FMA, which rounds once where the source rounds
twice). `-march` is pinned to a baseline rather than `native`.

The negative control proves this is not cargo cult: building with
`-Ofast -march=native`, which is what upstream's Makefile uses, produces a
**different** hash. The correct build emits **zero** FMA instructions; the
`-Ofast` build emits 96.

## Layout

```
mucore/            the engine. See mucore/README.md for full detail.
  mu_math.h        deterministic expf / sqrtf. Read this first.
  mu_core.h/.c     transformer, arena, tokenizer, argmax  (692 lines of code)
  tables/          measured RoPE table + its SHA-256
  hosts/posix/     development and testing harness
  hosts/baremetal/ freestanding aarch64, semihosting
  hosts/x86_64/    freestanding x86-64, PVH boot
  hosts/microkit/  seL4 protection domain + .system description
  tests/           determinism, cross-environment, parity, expf accuracy
model/             fetch.sh + pinned SHA256SUMS (blobs not committed)
vendor/llama2c/    upstream run.c, kept as the parity oracle, plus its LICENSE
vendor/microkit/   fetch.sh for the seL4 Microkit SDK (not committed)
documentation/     design.md — decisions and their justification
```

## Build

```sh
model/fetch.sh                  # hash-verified model inputs
vendor/microkit/fetch.sh        # seL4 Microkit SDK (for Stage C only)
cd mucore

make && make test               # build + determinism suite (7 tests)
make test-parity                # vs upstream llama2.c
make baremetal bm-run           # freestanding aarch64 under QEMU
make x86 x86-run                # freestanding x86-64 under QEMU
make microkit mk-run            # seL4 / Microkit protection domain
bash tests/cross_env.sh         # the six-environment comparison
```

Needs `clang`; for the freestanding and seL4 targets also
`brew install qemu llvm lld`.

```sh
./build/mu -m ../model/stories15M.bin -z ../model/tokenizer.bin \
           -r tables/rope_256x48.bin -i "Once upon a time" -n 80
```

## Scope

Deliberately narrow. This is a small, safe, reproducible inference engine and
nothing else.

Not included, on purpose: GPU support (it reintroduces signed vendor firmware
that boots before your code and, on NVIDIA, a closed kernel compiler — both
unavoidable holes in any verifiability claim), Linux, a distro or ISO,
temperature sampling, batching, and any model larger than the 15M-parameter
checkpoint the tests use.

`mucore/README.md` documents the measured results in full, including what is
and is not proven about seL4's verification status in this configuration.

## License

MIT, matching llama2.c. Attribution to Andrej Karpathy for the original.

# μInference

A verifiable minimum inference engine for LLMs.

## Characteristics

| | |
|---|---|
| **Verifiable** | Output is a pure function of its inputs. Verified bit-identical across 7 independent build and execution environments. |
| **Minimal** | **692 lines** of runtime trusted code. No libc, no libm, no heap, no threads. |
| **Reproducible** | Same logits from clang, gcc, `-O0` through `-O3`, aarch64, x86-64, bare metal, and seL4. |
| **Isolated** | Runs as a single seL4 protection domain with no channels, no device access, no Linux. |
| **Bounded** | Every allocation is a compile-time constant. 4.1 MB arena, no input can change it. |
| **Measured** | Weights and the RoPE table are pinned by SHA-256 and linked into the image, so one hash covers code and data. |

Derived from [llama2.c](https://github.com/karpathy/llama2.c) (MIT, Andrej
Karpathy). The arithmetic is faithful to the original; output is byte-identical
to it on 5/5 test prompts.

## Verifiability

One `mu_core.c`. Seven environments. Same logits, to the bit.

The fingerprint is SHA-256 over the raw float32 logits of every decode step
(3,072,000 bytes: 24 steps × 32000 vocab × 4), hashed by `shasum` rather than by
anything in this repo:

```
9b78b92a305dc59611b5c53a04b538ae9c4ae18aea6c1fdbf6e45e9848b23bd2
```

| # | Environment | libc | linker | FP implementation |
|---|---|---|---|---|
| 1 | hosted, clang, `-O2` | libSystem | ld64 | hardware FPU |
| 2 | hosted, clang, `-O0` | libSystem | ld64 | hardware FPU |
| 3 | hosted, second clang (different major version) | libSystem | ld64 | hardware FPU |
| 4 | hosted, **GCC** | libSystem | ld64 | hardware FPU |
| 5 | aarch64 bare metal, QEMU | **none** | ld.lld | hardware FPU |
| 6 | **x86-64** bare metal, QEMU | **none** | ld.lld | **QEMU softfloat SSE** |
| 7 | **seL4 / Microkit PD**, aarch64 | **none** | ld.lld | hardware FPU |

Rows 4 and 6 carry the most weight. GCC shares no frontend, optimiser or
backend with clang. And QEMU's x86 TCG evaluates SSE through its own softfloat
library rather than the host FPU, making it an independent floating point
*implementation* rather than another view of the same silicon.

Row 7 is the target deployment: a protection domain on a formally verified
microkernel, with no channels, no memory regions, no IRQs and no device
mappings. Its entire authority is its own address space plus the debug console.

## Why it's reproducible and vLLM isn't

Nondeterminism in production serving is not floating point noise. It is
**batch-invariance failure**: matmul, RMSNorm and attention change reduction
strategy with batch shape, and batch shape depends on server load. Making vLLM
deterministic costs 1.6–2× throughput.

A single-stream engine has no batch-invariance problem to solve, so it gets
determinism for free.

## How

IEEE-754 clause 5.4.1 **mandates** correct rounding for `+ − × ÷ √`. Clause 9.2
makes `exp`, `log`, `sin`, `cos`, `pow` *recommended only* — which is why libm
results differ between vendors, versions, and even vectorisation paths inside
one library.

So the engine uses nothing but mandated operations.

| Original | Here |
|---|---|
| `expf` (softmax, SwiGLU) | degree-7 Taylor, range reduction, `2^k` as a bit pattern. **Within 1 ULP** of the true result for every one of the 2³² possible inputs — proven by enumeration, not sampled. |
| `powf`, `cosf`, `sinf` (RoPE) | **gone from the runtime.** Precomputed offline into a table pinned by SHA-256. |
| `sqrtf` | hardware instruction, IEEE-754 mandated |
| `malloc`, `mmap`, OpenMP, RNG | one static arena, single-threaded, greedy `argmax` |

`-fno-fast-math` and `-ffp-contract=off` are part of the contract. FMA is
forbidden because it rounds once where the source rounds twice.

**The claim is falsifiable, and the suite proves it.** Building with
`-Ofast -march=native`, which is what upstream's Makefile uses, produces a
*different* hash. The correct build emits **zero** FMA instructions; that one
emits **96**.

## Minimum lines of code

Runtime trusted surface — everything that touches a logit:

| File | Lines |
|---|---|
| `mu_math.h` | 85 |
| `mu_core.h` | 133 |
| `mu_core.c` | 474 |
| **Total** | **692** |

For comparison, upstream `run.c` is 973 lines, and a vLLM + PyTorch + CUDA stack
is several million with a closed compiler at the bottom of it.

Hosts are swappable and not shared trusted surface: POSIX 159 lines, aarch64
bare metal 173 C + 165 asm, x86-64 182 C + 183 asm, seL4 PD 157 lines. Only
`hosts/` differs between deployments, which is why a determinism result measured
in one carries over to the others.

## Performance

161 tok/s single-threaded on Apple Silicon (256 tokens in 1.59 s), with no BLAS,
no SIMD intrinsics and no threading. Arena high-water mark 4,131,840 bytes,
identical in all seven environments.

```
$ mu -i "Lily found a shiny key" -n 100
Lily found a shiny key in her room. She did not know what it was for, but she
liked it. She put it in her pocket and went to play outside. She saw a big tree
with a hole in it. She thought it was a good place to hide the key.
```

## Build

```sh
model/fetch.sh                  # hash-verified model inputs
vendor/microkit/fetch.sh        # seL4 SDK, for the PD target only
cd mucore

make && make test               # build + determinism suite (7 tests)
make verify                     # formal verification (SPEC.md clauses)
make test-parity                # 5/5 identical to upstream llama2.c
make baremetal bm-run           # freestanding aarch64 under QEMU
make x86 x86-run                # freestanding x86-64 under QEMU
make microkit mk-run            # seL4 / Microkit protection domain
bash tests/cross_env.sh         # the seven-environment comparison
```

Needs `clang`; for freestanding and seL4 targets also `brew install qemu llvm lld`.

## Layout

```
mucore/            the engine
  mu_math.h        the determinism argument. Read this first.
  mu_core.h/.c     transformer, arena, tokenizer, argmax
  tables/          measured RoPE table + its SHA-256
  hosts/           posix · baremetal · x86_64 · microkit
  tests/           determinism · cross-environment · parity · expf accuracy
model/             fetch.sh + pinned SHA256SUMS
vendor/llama2c/    upstream run.c, kept as the parity oracle
vendor/microkit/   fetch.sh for the seL4 Microkit SDK
documentation/     design.md — decisions and why
```

## Scope

Small, safe, reproducible inference. Nothing else.

**No GPU, deliberately.** Any GPU path reintroduces signed vendor firmware
(GSP/PSP) that boots before your code and cannot be substituted, and on NVIDIA a
closed kernel compiler generating the machine code that computes your logits.
Neither hole is closeable by engineering, and either voids the claim.

Also absent on purpose: Linux, a distro or ISO, temperature sampling, and
batching.

## Formal verification

Reproducibility is tested. Some properties are now **proven**, machine-checked,
covering all inputs rather than a sample. Status lives in [SPEC.md](SPEC.md);
run it with `cd mucore && make verify`.

| Clause | Claim | Status |
|---|---|---|
| S2 | The arena never overruns and blocks never overlap | ✅ proven |
| S3a | Only exactly-rounded FP operations are used | ✅ proven |
| S4a | `mu_expf` is within 1 ulp of the true result | ✅ proven, all 2³² inputs |
| S4b | Error bound for the dot product loop | ✅ proven in Rocq, no added axioms |
| S1 | No undefined behaviour | 🟡 6 of 8 functions |
| S3b, S4c, S5 | see SPEC.md | ⬜ open |

## What is not proven

- QEMU only. No run on real hardware.
- Bit-identical *output* is demonstrated. Byte-identical *binaries* from
  independent builders is a different property and is not done.
- One checkpoint: stories15M, 15M parameters, seq_len 256. Untested at 7B.
- Greedy sampling only. Temperature needs a specified seeded PRNG.
- On seL4: the AArch64 configuration has functional correctness and integrity
  proofs. Confidentiality is in progress, information flow is not proven, binary
  verification covers AArch32/RISC-V64 not AArch64, no verified configuration on
  any architecture includes an IOMMU, and verified means single core. So: *runs
  on a formally verified microkernel as a single PD with no device access* — not
  "formally verified isolation on server hardware", which nobody can claim.

`mucore/README.md` has the full measured results. `documentation/design.md` has
the reasoning behind each decision.

## License

MIT, matching llama2.c. Attribution to Andrej Karpathy for the original.

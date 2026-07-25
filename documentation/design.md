# μInference design decisions

Replaces two earlier planning documents that were removed rather than kept as
drift: a PDR proposing seL4 virtualization on x86-64 with a Linux guest, and a
plan to add GPU acceleration via the `candle` crate. Both were invalidated by
what the primary sources actually say. This records what was decided instead,
and why, so the reasoning is not lost with the documents.

---

## D1. seL4 on AArch64, not x86-64

**Superseded:** "unverified x86-64 with VT-x, hosting a Linux guest."

From `CAVEATS.md` in the seL4 16.0.0 tree:

| Arch | Functional correctness | Integrity | Confidentiality | Info flow | Binary |
|---|---|---|---|---|---|
| **x86-64** | ✅ | ❌ | ❌ | ❌ | ❌ |
| AArch64 hyp | ✅ | ✅ | 🔶 in progress | ❌ | ❌ |
| RISC-V 64 | ✅ | ✅ | ✅ | ✅ | ✅ |
| AArch32 | ✅ | ✅ | ✅ | ✅ | ✅ |

x86-64 has a C-level functional-correctness proof and **zero security-property
proofs**. Isolation is exactly what it lacks. Worse, the verified x86-64
configuration is documented as being *"without VT-x and VT-d"*, so enabling the
virtualization the superseded plan required leaves the verified set entirely.

The empirical argument: **seL4 16.0.0 fixed a VM escape in `restore_vmx()`**
giving arbitrary kernel-mode code execution, rated Critical, present through
releases 13.0.0–15.0.0. Affected configurations: *"unverified x86-64
configurations with VT-x"* — precisely what was proposed.

AArch64 hypervisor config is the only verified configuration with both an FPU
and hypervisor extensions, so it is the target.

**Honest limits, stated because the value of this project is the accuracy of its
claims:** confidentiality on AArch64 is in progress and information flow is not
proven; binary-level verification covers AArch32 and RISC-V64, not AArch64, so
on AArch64 you trust the compiler and linker; **no verified configuration on any
architecture includes an IOMMU/SMMU**; and verified means **single core** (SMP is
unverified everywhere, with a static multi-kernel design as the planned route).
Every verified AArch64 platform is an embedded SoC — there is no verified seL4
configuration for any server-class machine.

## D2. Microkit, not CAmkES

**Superseded:** "use the upstream seL4 + CAmkES VMM."

Microkit has superseded CAmkES for new static systems; upstream ships a
migration guide and recommends Microkit for new work. `seL4/camkes-vm` has 26
stars and no releases. Active x86 VMM work lives in `au-ts/libvmm`.

Implemented against **Microkit 2.3.0**, board `qemu_virt_aarch64`, config
`debug` (the debug console is the PD's only output channel).

## D3. No Linux guest, no VMM

**Superseded:** "host the existing μInference Linux ISO as a guest under a VMM."

Wrapping Linux in a hypervisor buys nothing in TCB terms: the plaintext model
still sits in a 40-million-line kernel's address space with every driver it
loaded. The inversion is only possible because inference here is a few hundred
lines — you could not do this with PyTorch.

The PD declares no memory regions, no channels, no IRQs, and no device
mappings. Its entire authority is its own address space plus the debug console.

Corollary: the former requirement "no uncontrolled DMA" is met by having no
device access at all, rather than by configuring an IOMMU. That is fortunate,
because it could not have been met the other way: libvmm's manual states x86 DMA
passthrough is unsupported, and seL4's CAVEATS state that without IOMMU
interrupt remapping *"devices cannot be securely passed through to untrusted
virtual machines."*

## D4. CPU only. No GPU.

**Superseded:** the `candle` GPU plan.

Measured against that plan specifically:

- candle is **192,568 lines of code**. Not small.
- It requires `std`, so it cannot run natively in a protection domain.
- Its mandatory `rayon` and `gemm` dependencies change floating-point
  accumulation order by machine and thread count. That is precisely the
  invariance this project exists to have.
- Its CUDA feature pulls `cudarc` with cublas, cublaslt, curand, driver and
  nvrtc: five closed NVIDIA binaries. Choosing candle reduces the open-source
  surface without touching the closed one.

More fundamentally, **any** GPU path reintroduces two irreducible holes:

1. **Signed vendor firmware.** GSP on NVIDIA, PSP on AMD. Hardware-verified
   signatures, closed code, boots before yours, cannot be substituted.
2. **A closed kernel compiler**, on NVIDIA: NVRTC and ptxas generate the machine
   code that computes your logits.

Either one voids a verifiability claim. Neither is closeable by engineering.

Noted for completeness because it is genuinely the interesting alternative:
tinygrad drives an NVIDIA GPU from userspace in roughly **2,700 hand-written
lines**, versus **1,771,619** for NVIDIA's "open" kernel modules. If GPU support
is ever pursued, that is the shape — and AMD is strictly better than NVIDIA on
the closed-code axis, because comgr and Mesa's ACO are open where NVRTC is not.
It still does not close the firmware hole.

## D5. Determinism by construction, not by convention

IEEE-754 clause 5.4.1 mandates correct rounding for `+ − × ÷ √`; two conforming
implementations must agree bit-for-bit. Clause 9.2 lists the transcendentals as
*recommended only*. So the core is built exclusively from mandated operations.

- `expf` → degree-7 Taylor with range reduction, binary64 internals, `2^k`
  assembled as a bit pattern. Measured **within 1 ULP** of platform libm across
  16M sample points, 98.87% bit-exact, `exp(0) == 1.0` exactly.
- `powf`/`cosf`/`sinf` → deleted from the runtime; RoPE reads a table generated
  offline and pinned by SHA-256. This is the "verify the state of the world
  rather than trusting the process that produced it" principle applied to a
  lookup table.
- `sqrtf` → hardware instruction, IEEE-754 mandated. The `sqrt(head_size)` use
  is hoisted as a constant.
- No threads, no OpenMP, no heap, no RNG. Greedy sampling only.

Build flags are part of the contract: `-fno-fast-math -ffp-contract=off
-fno-unsafe-math-optimizations`, and `-march` pinned to a baseline rather than
`native`. FMA is forbidden because it rounds once where the source rounds twice.

Verified by a negative control rather than assertion: `-Ofast -march=native`
produces a different logits hash, and emits 96 FMA instructions where the
correct build emits zero.

## D6. Model inputs are pinned, not vendored

The checkpoint and tokenizer are fetched by `model/fetch.sh` and verified
against a committed `SHA256SUMS`, which refuses to leave an unverified blob on
disk. An unpinned checkpoint would make the reproducibility claim meaningless,
since the output is only a pure function of its inputs if the inputs are known.

Weights are linked into the freestanding and Microkit images rather than loaded
from a filesystem, so one hash over the image covers code and weights together.

## D7. What was deleted

Removed outright rather than deprecated, at the owner's instruction. Tracked
files remain recoverable from git history.

- `l2e_boot/` — the Linux + BusyBox + musl + Limine ISO build (1.9 GB of
  downloaded sources). Superseded by D3. It also pinned **Linux 6.5.0**, which
  was never an LTS and went EOL in December 2023: roughly two and a half years
  of unpatched kernel CVEs inside a project whose pitch is a small trusted base.
- Root `Makefile`, `bg.png`, `.github/workflows/build-iso.yml` — ISO build
  orchestration and its CI.
- `documentation/` slides and `project.docx` — presentation material describing
  the superseded architecture.
- `documentation/pdr_se4l_virtualization.md`, `plan_gpu_candle.md` — the two
  plans this document replaces.
- Most of `llama2c/` — Python training code, notebooks, prebuilt binaries, MSVC
  and Windows shims. Kept: `run.c` as the parity oracle, and the MIT `LICENSE`.

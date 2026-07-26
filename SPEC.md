# μInference specification

What is claimed, how each claim is discharged, and what is still open.

Nothing is marked ✅ here until `mucore/tests/verify.sh` proves it. Run it:

```sh
cd mucore && make verify
```

Requires `cbmc` (`brew install cbmc`) and clang.

## Status

| Clause | Claim | Method | Status |
|---|---|---|---|
| **S1** | No undefined behaviour, for any input | CBMC | 🟡 6 of 8 functions |
| **S2** | The arena never overruns and blocks never overlap | CBMC | ✅ **proven** |
| **S3a** | Only exactly-rounded FP operations are used | LLVM IR check | ✅ **proven** |
| **S3b** | Output depends only on the inputs | CompCert | ⬜ open |
| **S4a** | `mu_expf` is within 1 ulp of the true result | exhaustive | ✅ **proven** |
| **S4b** | Error bound for the matrix multiply | Rocq proof | ✅ **proven** |
| **S4c** | End-to-end error bound for one token | compose S4a, S4b | ⬜ open |
| **S5** | It computes a transformer correctly | Coq | ⬜ deferred |

---

## S1 — No undefined behaviour 🟡 partial

**Claim.** For any input accepted by `mu_model_init` and `mu_tok_init`, no
execution reads or writes outside an object, overflows a signed integer,
divides by zero, or fails to terminate.

**Method.** CBMC, bounded model checking. Every loop is fully unwound and
`--unwinding-assertions` makes an insufficient bound a hard failure, so no
result here is a silent under-approximation.

One substitution is made under CBMC only, and it is load-bearing: `mu_sqrtf`
normally uses inline assembly (`fsqrt` on AArch64, `sqrtss` on x86-64), and CBMC
does not model inline asm — it silently treats the block as having no effect,
which would make any result about a function using sqrt meaningless. Under
`__CPROVER__` the function calls `sqrtf`, which CBMC models as the IEEE-754
square root, exactly what the assembly computes. The shipping build is unchanged
and S3a independently confirms it links no libm.

**Proven** (`mucore/tests/cbmc_units.c`, 3023–3099 checks each, all discharged):

| Function | Symbolic over | Result |
|---|---|---|
| `mu_argmax` | length `n ∈ [1,8]`, all values | index always in `[0,n)` |
| `mu_matmul` | `n,d ∈ [1,6]` | no access outside `w[n·d)`, `x[n)`, `out[d)` |
| `mu_softmax` | length `n ∈ [1,8]` | no out-of-bounds access |
| `mu_rmsnorm` | length `n ∈ [1,8]` | no out-of-bounds access |
| `mu_tok_decode` | blob bytes, offsets, lengths, `out_cap` | never writes more than `out_cap` |
| `mu_tok_init` | **every byte of a 20-byte blob**, blob length | rejects malformed input rather than reading out of bounds; on success every record lies inside the blob |

`mu_tok_init` is the one that matters most for security: it parses untrusted
length-prefixed records out of a tokenizer file. With the blob fully symbolic,
CBMC proves the `off + len > blob_bytes` rejection cannot be bypassed for any
byte pattern of that length.

**Not yet covered.** `mu_forward` end to end, `mu_tok_encode`.

**Why `mu_forward` whole is not done.** CBMC encodes IEEE-754 bit-precisely.
One forward pass is thousands of float operations, and the harness did not
finish in ten minutes even on an 8-dimension model. That cost buys nothing for
memory safety, because **no index in the engine depends on a float value** —
float values reach control flow only through the two `>` comparisons in
`mu_softmax` and `mu_argmax`, and both branches of each are index-safe. Unit
harnesses with symbolic sizes are cheaper and prove more, since each result
holds for a range of shapes rather than one config.

Bound sizes are also a real limit: these results hold for the stated ranges, not
for `dim = 4096`. Completing S1 needs Frama-C with loop invariants over a
symbolic `dim`, which would cover all configs. Frama-C is not packaged for
Homebrew and needs an opam toolchain.

One practical note recorded because it cost time: symbolic state is the binding
constraint, not loop count. A 48-byte symbolic tokenizer blob did not finish in
eight minutes; the same harness at 20 bytes finishes in 0.7 s. Per-loop bounds
(`--unwindset`) matter too — `mu_tok_init` needs 257 unwindings for its
`byte_pieces` table, and applying that globally makes the parser intractable.

## S2 — Arena bounds ✅ proven

**Claim.** `mu_arena_alloc` returns either NULL or a 64-byte-aligned block lying
wholly inside the arena and not overlapping any earlier block. `used` never
exceeds `size` and never decreases.

**Method.** CBMC over a symbolic arena size and three symbolic allocation sizes.
Pure integer arithmetic, so the result is exact. Three allocations is the
minimum that can expose an overlap bug: it needs a previous block, a current
one, and a following one.

All 3099 checks discharged, including alignment, containment, non-overlap and
monotonicity.

## S3a — Only exactly-rounded operations ✅ proven

**Claim.** Every floating-point operation the compiler emits for `mu_core.c` is
one that IEEE-754 clause 5.4.1 requires to be correctly rounded: `+ − × ÷ √`,
plus format conversions and comparisons. No fast-math flags. No FMA. No libm.

**Method.** Static analysis of the LLVM IR *after optimisation*, at `-O0`,
`-O1`, `-O2`, `-O3` and `-Os`. Checking the C source would be weaker: the source
says `val += w[j]*x[j]`, but what runs is whatever the optimiser produced, and
the optimiser may fuse, reassociate or vectorise.

**What this caught.** The core *is* auto-vectorised — 61
`llvm.vector.reduce.fadd` calls at `-O2` and `-O3`. That is safe only because
they are the **ordered** form; LLVM's `vector.reduce.fadd` is strictly
sequential unless it carries `reassoc`, at which point the summation order
becomes unspecified and reproducibility is gone. Zero of them carry it, and zero
FP instructions in the module carry any fast-math flag. The check fails if that
ever changes.

**Negative control.** Building `-Ofast -march=native` produces 331 fast-math
flagged instructions and is correctly rejected.

## S3b — Semantic determinism ⬜ open

**Claim.** Given S3a, and a compiler whose output provably preserves source-level
IEEE-754 semantics, the logits are a function of the inputs alone — identical on
every platform conforming to IEEE-754 with round-to-nearest-even.

**Method.** S3a plus a CompCert build. CompCert models floats with Flocq and has
a machine-checked proof that generated assembly matches the source semantics.
It supports AArch64, x86-64 and RISC-V.

**Currently.** Tested on seven environments, not proven. See the cross-environment
suite. Testing samples the input space; this clause would cover it.

## S4a — `mu_expf` error bound ✅ proven

**Claim.** For every binary32 `x` in `[-103.97, 88.72]` whose true `exp(x)` is a
normal binary32 number, `mu_expf(x)` is within 1 ulp of the correctly-rounded
result. `mu_expf(0) = 1` exactly.

**Method.** Exhaustive enumeration of all 2³² binary32 bit patterns, compared
against `(float)exp((double)x)`. This is a complete case analysis over the whole
domain — nothing sampled, nothing extrapolated. For a single-argument float32
function it is stronger than an interval bound: it establishes the exact worst
case and where it occurs.

**Result** (`mucore/tests/exhaustive_expf.c`, 3.4 s on 8 threads):

```
inputs in the normal domain   2,237,668,968
bit-exact vs reference        2,236,503,555   (99.9479%)
within 1 ulp                  2,237,668,968   (100.0000%)
worst case                    1 ulp, at x = 0.0808606073 (0x3da59a3f)
clamp contract violations     0
```

**Documented deviations from `exp`**, both deliberate and both checked:
`x < −103.97` returns `+0` where `exp` gives a subnormal, and `x > 88.72` returns
`FLT_MAX` where `exp` gives `+inf`. NaN and infinite inputs are out of contract —
the engine never produces them as arguments, because softmax subtracts the row
maximum first and SwiGLU negates a finite activation.

**Why not Gappa.** Gappa would prove the bound from the polynomial's structure
rather than by enumeration, which also extends to binary64. It is not packaged
for Homebrew. Worth adding, but it would not strengthen the binary32 claim.

## S4b — Dot product error bound ✅ proven

**Claim.** For the loop `for (j=0;j<n;j++) val += w[j]*x[j]` under the standard
floating-point model `fl(x op y) = (x op y)(1+d)`, `|d| <= u`:

```
|computed - exact|  <=  gamma_n * sum |a_i b_i|,    gamma_n = (1+u)^(n+1) - 1
```

**Method.** A machine-checked proof in Rocq 9.2, `proofs/DotError.v`. Not an
instantiation of LAProof — written directly, because the statement is short
enough that a self-contained proof is easier to audit than a dependency.

Three results, all with **no `Admitted` and no added axioms**:

| Theorem | Statement |
|---|---|
| `dot_error` | the bound, for a right-associated fold |
| `dot_error_loop` | the bound with a running accumulator, including the accumulator's own error term |
| `dot_error_loop_from_zero` | corollary at `acc = 0`, which is the C loop verbatim |

```coq
dot_error_loop_from_zero
  : forall u : R, 0 <= u ->
    forall (l : list (R * R)) (r : R),
    computes_from u 0 l r ->
    Rabs (r - dot l) <= gamma u (length l) * adot l
```

`Print Assumptions` reports exactly two axioms, `sig_forall_dec` and
`functional_extensionality_dep`, which are what Rocq's classical reals are built
on. Every proof about `R` depends on them; nothing was assumed here.

**Why two fold directions.** The first theorem associates right; the C loop
accumulates left. The bound is the same, but proving one and claiming it covers
the other would be sleight of hand, so `computes_from` models the loop verbatim
and `dot_error_loop_from_zero` is the result that actually applies.

**Two things the proof forced into the open.** The accumulator bound must be
`(|acc| + |P|(1+u))(1+u)`, not `(|acc| + |P|)(1+u)` — the product is already
rounded before the add, so it carries its own factor, and with the looser form
the induction does not close. And `u < 1`, which the standard treatment assumes,
turns out to be unnecessary: the bound holds for any `u >= 0`. The hypothesis
was removed rather than left in place looking load-bearing.

**What this does not cover.** Underflow. The multiplicative model is exactly
what fails for subnormal results, so the bound is conditional on no underflow
occurring. This is a property of the model, not of the proof, and it is the one
assumption that could bite in practice.

## S4c — End-to-end error bound ⬜ open

Compose S4a, S4b and an RMSNorm bound into a per-token logit error bound. First
clause that is genuinely hard.

## S5 — Functional correctness ⬜ deferred

**Claim.** There is a reference transformer `T` over ℝ in Coq such that
`‖mu_forward(token, pos) − T(weights, tokens)‖∞ ≤ δ` for `δ` from S4c.

**Deferred on purpose.** This needs a reference transformer written in Coq, which
is a project in its own right. S1–S4 are a stronger claim than any inference
engine currently has, and S5 without them would not be worth much.

---

## What verification cannot do here

A proof is universally quantified over inputs and checked once, offline. It says
nothing about one specific run. To show what happened on a particular request you
need attestation or re-execution. Proofs make the engine worth trusting as the
thing that re-executes; they are not a receipt.

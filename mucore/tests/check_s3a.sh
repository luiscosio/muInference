#!/usr/bin/env bash
# S3a — only exactly-rounded floating-point operations are used.
#
# THE CLAIM
#   Every floating-point operation the compiler emits for mu_core.c is one that
#   IEEE-754 clause 5.4.1 requires to be correctly rounded: + - * / sqrt, plus
#   format conversions and comparisons. Nothing carries a fast-math flag. No
#   FMA. No libm.
#
# WHY THIS IS THE RIGHT PLACE TO CHECK
#   Checking the C source would be weaker. The source says `val += w[j]*x[j]`,
#   but what actually runs is whatever the optimiser produced, and the optimiser
#   is free to fuse, reassociate or vectorise. So this inspects the LLVM IR the
#   backend will lower, after all optimisation has run. If it is clean there,
#   the arithmetic that executes is the arithmetic the standard pins down.
#
# WHAT IT CAUGHT
#   The core does get auto-vectorised: 61 llvm.vector.reduce.fadd calls at -O2.
#   That is safe only because they are the ORDERED form. LLVM's
#   vector.reduce.fadd is strictly sequential unless it carries `reassoc`, in
#   which case the summation order becomes unspecified and reproducibility is
#   gone. This script fails if any of them is ever flagged.
#
# Exit 0 = S3a holds for this build configuration.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CORE="$ROOT/mucore/mu_core.c"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

CLANG="${CLANG:-$( [ -x /opt/homebrew/opt/llvm/bin/clang ] && echo /opt/homebrew/opt/llvm/bin/clang || echo clang )}"
DET="-fno-fast-math -ffp-contract=off -fno-unsafe-math-optimizations"

# Baseline ISA must match the host, or the compile fails outright. Hardcoding
# armv8-a made this pass on a Mac and fail on an x86-64 CI runner.
case "$(uname -m)" in
  arm64|aarch64) ISA="-march=armv8-a"    ;;
  x86_64|amd64)  ISA="-march=x86-64-v2"  ;;
  *)             ISA=""                  ;;
esac

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }

echo
echo "=== S3a: only exactly-rounded FP operations ======================"
echo "compiler: $("$CLANG" --version | head -1)"
echo "host:     $(uname -m)   baseline ISA: ${ISA:-none}"

# Checked at every optimisation level, because vectorisation and fusion
# decisions change with -O and a claim that only holds at -O2 is not a claim.
for OPT in -O0 -O1 -O2 -O3 -Os; do
  IR="$TMP/core$OPT.ll"
  if ! "$CLANG" -std=c11 $OPT $DET $ISA -I"$ROOT/mucore" \
        -S -emit-llvm -o "$IR" "$CORE" 2>"$TMP/err"; then
    bad "$OPT could not be compiled to IR"
    sed 's/^/            /' "$TMP/err" | head -4
    continue
  fi

  probs=""

  # 1. Fast-math flags on any FP instruction. Any one of these is a licence to
  #    reassociate or fuse, which breaks reproducibility.
  n=$(grep -cE '^[^;]*\b(fadd|fsub|fmul|fdiv|frem|fneg|fcmp)\b[^;]*\b(fast|reassoc|nnan|ninf|nsz|arcp|contract|afn)\b' "$IR" || true)
  [ "$n" != "0" ] && probs="$probs fast-math-flags($n)"

  # 2. Fused multiply-add. Rounds once where the source rounds twice.
  n=$(grep -cE '@llvm\.(fma|fmuladd)\.' "$IR" || true)
  [ "$n" != "0" ] && probs="$probs fma($n)"

  # 3. Transcendental intrinsics. Not required to be correctly rounded.
  n=$(grep -oE '@llvm\.(exp|exp2|exp10|log|log2|log10|sin|cos|tan|pow|powi)\.' "$IR" | wc -l | tr -d ' ')
  [ "$n" != "0" ] && probs="$probs transcendental-intrinsics($n)"

  # 4. Calls to libm. The core must not have any.
  n=$(grep -oE 'declare [^@]*@(exp|expf|log|logf|sin|sinf|cos|cosf|pow|powf|tan|tanf|fmod|fmodf|sqrt|sqrtf|exp2|exp2f|log2|log2f)\(' "$IR" | wc -l | tr -d ' ')
  [ "$n" != "0" ] && probs="$probs libm-decls($n)"

  # 5. frem — implemented as a libcall, not exactly rounded.
  n=$(grep -cE '^[^;]*\bfrem\b' "$IR" || true)
  [ "$n" != "0" ] && probs="$probs frem($n)"

  # 6. Relaxed vector reductions. The ordered form is fine and is what the
  #    optimiser actually emits; the reassoc form is not.
  n=$(grep -E '@llvm\.vector\.reduce\.(fadd|fmul)' "$IR" | grep -cE '\b(fast|reassoc)\b' || true)
  [ "$n" != "0" ] && probs="$probs unordered-reduction($n)"

  if [ -z "$probs" ]; then
    ordered=$(grep -cE '@llvm\.vector\.reduce\.(fadd|fmul)' "$IR" || true)
    ok "$(printf '%-4s clean   (%s ordered vector reductions)' "$OPT" "$ordered")"
  else
    bad "$(printf '%-4s%s' "$OPT" "$probs")"
  fi
done

# --- negative control -------------------------------------------------
# A checker that cannot fail proves nothing, so build the way upstream does
# and confirm the check rejects it.
echo
echo "--- negative control: -Ofast -march=native must be REJECTED ---"
IR="$TMP/bad.ll"
if "$CLANG" -std=c11 -Ofast -march=native -I"$ROOT/mucore" \
      -S -emit-llvm -o "$IR" "$CORE" 2>/dev/null; then
  flags=$(grep -cE '^[^;]*\b(fadd|fsub|fmul|fdiv)\b[^;]*\b(fast|reassoc)\b' "$IR" || true)
  fma=$(grep -cE '@llvm\.(fma|fmuladd)\.' "$IR" || true)
  if [ "$flags" != "0" ] || [ "$fma" != "0" ]; then
    ok "rejected as expected (fast-math on $flags instructions, $fma fma intrinsics)"
  else
    bad "-Ofast produced clean IR — the checker is not discriminating"
  fi
else
  bad "could not build the negative control"
fi

echo
echo "=== $pass passed, $fail failed ==================================="
echo
[ "$fail" -eq 0 ]

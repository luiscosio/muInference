#!/usr/bin/env bash
# Runs every formal-verification clause that currently has a discharge.
#
# Clause status lives in SPEC.md. Nothing is claimed there until it is green
# here. Each block prints which clause it discharges and by what method, so a
# reader can tell a proof from a test.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MU="$ROOT/mucore"
BUILD="$MU/build"
mkdir -p "$BUILD"

CLANG="${CLANG:-$( [ -x /opt/homebrew/opt/llvm/bin/clang ] && echo /opt/homebrew/opt/llvm/bin/clang || echo clang )}"
DET="-fno-fast-math -ffp-contract=off -fno-unsafe-math-optimizations"

pass=0; fail=0; skip=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
skp() { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; skip=$((skip+1)); }

echo
echo "################ muInference formal verification ################"

# ---------------------------------------------------------------- S1, S2
echo
echo "S1 / S2  no undefined behaviour, arena bounds   [CBMC, bounded model checking]"
if ! command -v cbmc >/dev/null 2>&1; then
  skp "cbmc not installed (brew install cbmc)"
else
  CHECKS="--bounds-check --pointer-check --pointer-overflow-check
          --div-by-zero-check --conversion-check
          --signed-overflow-check --unsigned-overflow-check
          --unwinding-assertions --no-standard-checks"
  # harness:unwind[:extra-cbmc-args]
  #
  # Bounds are sized so every loop is fully unwound. --unwinding-assertions
  # makes an insufficient bound a hard failure, so none of these results can
  # silently under-approximate.
  # mu_tok_init needs a per-loop bound of 257 for its byte_pieces table; giving
  # every loop that bound instead makes the parser intractable.
  for spec in H_ARENA:260 H_ARGMAX:20 H_MATMUL:50 H_DECODE:80 H_SOFTMAX:20 \
              H_RMSNORM:20 "H_TOKINIT:30:--unwindset mu_tok_init.0:257"; do
    h="${spec%%:*}"; rest="${spec#*:}"; u="${rest%%:*}"
    extra=""; case "$spec" in *:*:*) extra="${rest#*:}";; esac
    out=$(cbmc "$MU/tests/cbmc_units.c" -I"$MU" -D"$h" $CHECKS --unwind "$u" $extra 2>&1)
    n=$(echo "$out" | grep -oE '\*\* [0-9]+ of [0-9]+' | grep -oE '[0-9]+$')
    if echo "$out" | grep -q "VERIFICATION SUCCESSFUL"; then
      ok "$(printf '%-9s all %s checks discharged' "$h" "${n:-?}")"
    else
      bad "$h"
      echo "$out" | grep FAILURE | head -4 | sed 's/^/            /'
    fi
  done
fi

# ------------------------------------------------------------------- S3a
echo
echo "S3a      only exactly-rounded FP operations      [static check of LLVM IR]"
if bash "$MU/tests/check_s3a.sh" >"$BUILD/s3a.log" 2>&1; then
  n=$(grep -c PASS "$BUILD/s3a.log")
  ok "clean at -O0/-O1/-O2/-O3/-Os, negative control rejected ($n checks)"
else
  bad "see build/s3a.log"; grep -E "FAIL" "$BUILD/s3a.log" | head -5 | sed 's/^/            /'
fi

# ------------------------------------------------------------------- S4a
echo
echo "S4a      mu_expf within 1 ulp                    [exhaustive over 2^32 inputs]"
if "$CLANG" -std=c11 -O2 $DET -I"$MU" -pthread \
      -o "$BUILD/exhaustive_expf" "$MU/tests/exhaustive_expf.c" -lm 2>/dev/null; then
  if out=$("$BUILD/exhaustive_expf" 2>&1); then
    w=$(echo "$out" | grep -oE 'WORST CASE +[0-9]+ ulp' | grep -oE '[0-9]+')
    n=$(echo "$out" | grep -oE 'normal domain +[0-9]+' | grep -oE '[0-9]+')
    ok "worst case ${w} ulp over all ${n} in-domain inputs, not sampled"
  else
    bad "exhaustive check reported a violation"
    echo "$out" | grep -E "FAIL" | sed 's/^/            /'
  fi
else
  bad "could not build the exhaustive checker"
fi

# --------------------------------------------------------- not yet done
echo
echo "Not yet discharged"
printf '  \033[33m----\033[0m  %s\n' \
  "S1  remaining: mu_forward end to end, mu_tok_encode" \
  "S3b semantic determinism: needs a CompCert build" \
  "S4b matmul error bound: needs LAProof instantiation in Coq" \
  "S4c end-to-end logit error bound" \
  "S5  functional correctness against a reference transformer"

echo
echo "################ $pass passed, $fail failed, $skip skipped ################"
echo
[ "$fail" -eq 0 ]

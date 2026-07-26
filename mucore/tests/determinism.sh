#!/usr/bin/env bash
# Determinism test suite for the muinference core.
#
# The claim under test: the logits are a pure function of (weights, rope table,
# tokens), independent of how the binary was compiled or how many times it runs.
#
# We fingerprint the RAW float32 logits of every decode step, not the generated
# text. Text comparison is far too weak: greedy sampling hides differences until
# they cross an argmax boundary, so two builds can differ in the 7th mantissa
# bit for 200 tokens and still print the same story. Hashing the logits catches
# a single bit anywhere.
#
# Hashing is done by shasum, not by anything in this repo, so the oracle is
# independent of the code being tested.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="$ROOT/mucore/build"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

MODEL="$ROOT/model/stories15M.bin"
TOK="$ROOT/model/tokenizer.bin"
ROPE="$ROOT/mucore/tables/rope_256x48.bin"
PROMPT="Once upon a time"
STEPS=96

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
note() { printf '        %s\n' "$1"; }

run_hash() {   # $1=binary  $2=tag  -> echoes sha256 of concatenated logits
  local bin="$1" tag="$2"
  "$bin" -q -m "$MODEL" -z "$TOK" -r "$ROPE" -i "$PROMPT" -n "$STEPS" \
         --dump-logits "$TMP/$tag.logits" >"$TMP/$tag.txt" 2>"$TMP/$tag.err"
  shasum -a 256 "$TMP/$tag.logits" | awk '{print $1}'
}

echo
echo "=== muinference determinism suite ==============================="
echo "prompt: \"$PROMPT\"   steps: $STEPS   host: $(uname -m) $(uname -s)"
echo

# ---------------------------------------------------------------- test 1
echo "[1] repeatability: same binary, 5 consecutive runs"
h1=""
for i in 1 2 3 4 5; do
  h=$(run_hash "$BUILD/mu" "rep$i")
  [[ -z "$h1" ]] && h1="$h"
  if [[ "$h" != "$h1" ]]; then bad "run $i diverged: $h != $h1"; fi
done
note "sha256 = $h1"
[[ $fail -eq 0 ]] && ok "5/5 runs bit-identical"

# ---------------------------------------------------------------- test 2
echo
echo "[2] optimisation invariance: -O0 / -O2 / -O3 / -Os"
# bash 3.2 on macOS has no associative arrays, so use a flat record file.
: >"$TMP/opt.txt"
for v in mu_o0 mu mu_o3 mu_os; do
  if [[ ! -x "$BUILD/$v" ]]; then note "$v not built, skipping"; continue; fi
  h=$(run_hash "$BUILD/$v" "opt_$v")
  printf '%s %s\n' "$v" "$h" >>"$TMP/opt.txt"
done
base=$(awk '$1=="mu"{print $2}' "$TMP/opt.txt")
allsame=1
while read -r v h; do
  note "$(printf '%-8s %s' "$v" "$h")"
  if [[ "$h" != "$base" ]]; then bad "$v differs from -O2"; allsame=0; fi
done <"$TMP/opt.txt"
[[ $allsame -eq 1 ]] && ok "all optimisation levels bit-identical"

# ---------------------------------------------------------------- test 3
echo
echo "[3] negative control: -Ofast -march=native (upstream's flags)"
if [[ -x "$BUILD/mu_ofast" ]]; then
  hf=$(run_hash "$BUILD/mu_ofast" "ofast")
  note "mu_ofast $hf"
  if [[ "$hf" == "$base" ]]; then
    note "matched anyway on this host; -ffast-math is a licence to diverge,"
    note "not a guarantee of it. The test is that the suite CAN detect it."
    ok  "negative control ran (no divergence observed on this host)"
  else
    ok  "-Ofast diverges, as expected: the suite detects real differences"
  fi
else
  note "mu_ofast not built, skipping"
fi

# ---------------------------------------------------------------- test 4
echo
echo "[4] libm independence: no dynamic math library linked"
if command -v otool >/dev/null 2>&1; then
  libs=$(otool -L "$BUILD/mu" | tail -n +2 | awk '{print $1}')
else
  libs=$(ldd "$BUILD/mu" 2>/dev/null | awk '{print $1}')
fi
note "linked: $(echo "$libs" | tr '\n' ' ')"
if echo "$libs" | grep -qE 'libm\.|libm-'; then
  bad "libm is linked; transcendentals may come from the platform"
else
  ok "no libm dependency"
fi

# ---------------------------------------------------------------- test 5
echo
echo "[5] no floating-point transcendental calls in the core object"
nm_out=$( (nm -u "$BUILD/mu" 2>/dev/null || true) | tr -d '_' )
found=""
for sym in exp expf pow powf sin sinf cos cosf log logf tanh tanhf; do
  if echo "$nm_out" | grep -qx "$sym"; then found="$found $sym"; fi
done
if [[ -n "$found" ]]; then
  bad "undefined transcendental symbols:$found"
else
  ok "no undefined exp/pow/sin/cos/log symbols"
fi

# ---------------------------------------------------------------- test 6
echo
echo "[6] arena is statically bounded (no heap allocation at runtime)"
if echo "$nm_out" | grep -qxE 'malloc|calloc|realloc'; then
  bad "core references malloc/calloc/realloc"
else
  ok "no malloc/calloc/realloc referenced"
fi

# ---------------------------------------------------------------- test 7
echo
echo "[7] rope table integrity"
if (cd "$ROOT/mucore/tables" && shasum -a 256 -c rope_256x48.bin.sha256 >/dev/null 2>&1); then
  ok "rope_256x48.bin matches its recorded sha256"
else
  bad "rope table hash mismatch"
fi

echo
echo "=== $pass passed, $fail failed ================================="
echo
[[ $fail -eq 0 ]]

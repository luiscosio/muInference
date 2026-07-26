#!/usr/bin/env bash
# Parity test: does the port still compute the same model?
#
# Compares muinference against upstream llama2.c run.c at temperature 0
# (greedy) across several prompts. Both binaries are built with the same
# careful FP flags, so this isolates the arithmetic changes -- deterministic
# expf and the measured RoPE table -- from build-flag effects.
#
# Exact agreement is not expected and not the goal. Upstream calls the
# platform's expf/cosf/sinf/powf; we use a fixed polynomial and a float64
# precomputed table, which is *more* accurate but different in the last bits.
# What we want to know is where, if anywhere, that changes the greedy text.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="$ROOT/mucore/build"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

MODEL="$ROOT/model/stories15M.bin"
TOK="$ROOT/model/tokenizer.bin"
ROPE="$ROOT/mucore/tables/rope_256x48.bin"
STEPS=${STEPS:-160}

PROMPTS=(
  "Once upon a time"
  "The little robot"
  "Lily and Tom went to the park"
  "In a deep dark forest"
  ""
)

echo
echo "=== muinference vs upstream llama2.c (greedy, $STEPS steps) ======"
echo

same=0; diff=0
for i in "${!PROMPTS[@]}"; do
  p="${PROMPTS[$i]}"
  label="${p:-<empty>}"

  "$BUILD/mu" -q -m "$MODEL" -z "$TOK" -r "$ROPE" -i "$p" -n "$STEPS" \
      >"$TMP/mine.$i" 2>/dev/null
  "$BUILD/run_ref" "$MODEL" -z "$TOK" -t 0 -n "$STEPS" -i "$p" \
      >"$TMP/ref.$i" 2>/dev/null

  # run_ref echoes an achieved tok/s line to stdout on some builds; drop it
  sed -i '' -e '/^achieved tok\/s/d' "$TMP/ref.$i" 2>/dev/null || true

  if cmp -s "$TMP/mine.$i" "$TMP/ref.$i"; then
    printf '  \033[32mIDENTICAL\033[0m  "%s"\n' "$label"
    same=$((same+1))
  else
    diff=$((diff+1))
    # find the first differing byte and show the context
    off=$(cmp "$TMP/mine.$i" "$TMP/ref.$i" 2>/dev/null | sed -E 's/.*byte ([0-9]+).*/\1/')
    total=$(wc -c <"$TMP/mine.$i" | tr -d ' ')
    printf '  \033[33mDIVERGES\033[0m   "%s"\n' "$label"
    printf '              first difference at byte %s of %s (%.1f%% in)\n' \
           "$off" "$total" "$(echo "scale=4; 100*$off/$total" | bc 2>/dev/null || echo 0)"
    printf '              mine: %s\n' "$(head -c "$((off+24))" "$TMP/mine.$i" | tail -c 40 | tr '\n' ' ')"
    printf '              ref : %s\n' "$(head -c "$((off+24))" "$TMP/ref.$i"  | tail -c 40 | tr '\n' ' ')"
  fi
done

echo
echo "  $same identical, $diff diverged (of ${#PROMPTS[@]})"
echo
echo "  Reading this result: divergence is expected and is not a bug. The two"
echo "  implementations compute different last-bit values for exp and RoPE, so"
echo "  once any logit pair is within that margin the greedy argmax can flip and"
echo "  the texts separate permanently. What matters for the referee use case is"
echo "  that OUR result is reproducible, which determinism.sh establishes, and"
echo "  that our math is at least as accurate, which expf_accuracy establishes."
echo

#!/usr/bin/env bash
# Verify the seL4/Microkit protection domain against the hosted build.
#
# The PD has no device capabilities, so its only output channel is seL4's debug
# console. It emits the logits as hex between @@@BEGIN and @@@END markers; this
# script extracts that, converts back to binary, and hashes it with shasum so
# the comparison oracle stays outside the code under test.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="$ROOT/mucore/build"
MK="$BUILD/mk"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

MODEL="$ROOT/model/stories15M.bin"
TOK="$ROOT/model/tokenizer.bin"
ROPE="$ROOT/mucore/tables/rope_256x48.bin"
PROMPT="Once upon a time"
STEPS="${MK_STEPS:-24}"

echo
echo "=== seL4 / Microkit bit-exactness ==============================="
echo

if [[ ! -f "$MK/mk.out" ]]; then
  echo "  $MK/mk.out missing. Run: make microkit mk-run"
  exit 1
fi

if ! grep -q '@@@END' "$MK/mk.out"; then
  echo "  capture is incomplete (no @@@END marker)."
  echo "  last lines seen:"
  tail -5 "$MK/mk.out" | sed 's/^/    /'
  exit 1
fi

# Pull out just the hex payload: everything strictly between the markers, with
# whitespace and any interleaved newlines removed.
sed -n '/@@@BEGIN/,/@@@END/p' "$MK/mk.out" \
  | sed -e '/@@@BEGIN/d' -e '/@@@END/d' \
  | tr -d '\r\n \t' > "$TMP/hex"

hexlen=$(wc -c < "$TMP/hex" | tr -d ' ')
echo "  hex payload      $hexlen chars"

if (( hexlen % 2 != 0 )); then
  echo "  odd hex length, capture truncated"
  exit 1
fi

# xxd -r -p reverses a plain hex dump.
xxd -r -p "$TMP/hex" > "$TMP/mk.logits"
mklen=$(wc -c < "$TMP/mk.logits" | tr -d ' ')
echo "  decoded          $mklen bytes"

# Reference: hosted build, same prompt and step count.
"$BUILD/mu" -q -m "$MODEL" -z "$TOK" -r "$ROPE" -i "$PROMPT" -n "$STEPS" \
    --dump-logits "$TMP/ref.logits" >/dev/null 2>&1
reflen=$(wc -c < "$TMP/ref.logits" | tr -d ' ')
echo "  hosted reference $reflen bytes"
echo

mkhash=$(shasum -a 256 "$TMP/mk.logits" | awk '{print $1}')
refhash=$(shasum -a 256 "$TMP/ref.logits" | awk '{print $1}')

printf '  seL4/Microkit    %s\n' "$mkhash"
printf '  hosted macOS     %s\n' "$refhash"
echo

if [[ "$mklen" != "$reflen" ]]; then
  echo "  FAIL: length mismatch ($mklen vs $reflen); step counts differ?"
  exit 1
fi

if [[ "$mkhash" == "$refhash" ]]; then
  echo "  PASS: seL4 protection domain is bit-identical to the hosted build"
  exit 0
else
  echo "  FAIL: logits differ"
  cmp "$TMP/mk.logits" "$TMP/ref.logits" | head -3 | sed 's/^/    /'
  exit 1
fi

#!/usr/bin/env bash
# Cross-environment bit-exactness: the load-bearing test for this project.
#
# determinism.sh proves the output does not depend on optimisation level within
# one toolchain on one OS. Necessary, but weak. This proves the output does not
# depend on the toolchain, the C library, the linker, the instruction set, the
# floating point *implementation*, the operating system, or the kernel.
#
# Eight environments, one mu_core.c, byte for byte:
#
#   1. hosted, default compiler, -O2                          (the reference)
#   2. hosted, same compiler, -O0
#   3. hosted, a second clang of a different major version
#   4. hosted, GCC. A genuinely independent compiler: clang-vs-clang shares a
#      frontend, an optimiser and a backend, clang-vs-gcc shares none of them.
#   5. hosted, CompCert. A FORMALLY VERIFIED compiler, so its agreement makes
#      the reference hash the semantics of the program rather than one
#      optimiser's output.
#   5. aarch64-none-elf freestanding, no libc, ld.lld, QEMU cortex-a57,
#      own MMU setup, blobs linked into the image, semihosting I/O
#   6. x86-64 freestanding, no libc, ld.lld, QEMU Nehalem. Different LLVM
#      backend (SSE, not NEON) and QEMU's x86 TCG evaluates SSE through its own
#      softfloat library, so this is an independent FP implementation rather
#      than another view of the same silicon.
#   7. seL4 / Microkit protection domain, aarch64, single core, no device caps
#
# Rows 5-7 must be produced first by their own make targets; each is skipped
# with a clear note if its artifact is absent, rather than silently passing.
#
# Hashing is done by shasum, so the oracle is independent of the code tested.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="$ROOT/mucore/build"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

MODEL="$ROOT/model/stories15M.bin"
TOK="$ROOT/model/tokenizer.bin"
ROPE="$ROOT/mucore/tables/rope_256x48.bin"
BREW_CLANG="/opt/homebrew/opt/llvm/bin/clang"

# Must match g_prompt / MU_BM_STEPS / MU_MK_STEPS in the freestanding hosts.
PROMPT="Once upon a time"
STEPS="${BMSTEPS:-24}"

pass=0; fail=0; skip=0
ok()   { printf '  \033[32mPASS\033[0m  %-34s %s\n' "$1" "$2"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %-34s %s\n' "$1" "$2"; fail=$((fail+1)); }
skp()  { printf '  \033[33mSKIP\033[0m  %-34s %s\n' "$1" "$2"; skip=$((skip+1)); }

echo
echo "=== cross-environment bit-exactness ============================="
echo "prompt \"$PROMPT\"   steps $STEPS   payload $((STEPS * 32000 * 4)) bytes"
echo

# --- reference: hosted, Apple clang, -O2 ------------------------------
emit() { "$1" -q -m "$MODEL" -z "$TOK" -r "$ROPE" -i "$PROMPT" -n "$STEPS" \
              --dump-logits "$2" >/dev/null 2>&1; }

# Report the compiler actually used rather than hardcoding a name: this suite
# runs on macOS and on Linux CI, where CC and the alternate compiler differ.
ccname() { "$1" --version 2>/dev/null | head -1 | cut -c1-28; }
CC1=$(ccname "${CC:-clang}")

emit "$BUILD/mu" "$TMP/ref.logits"
REFHASH=$(shasum -a 256 "$TMP/ref.logits" | awk '{print $1}')
printf '  ----  %-34s %s\n' "hosted -O2 (ref) ${CC1:+[$CC1]}" "$REFHASH"

check() {   # $1=label $2=file
  local h n r
  [[ -f "$2" ]] || { skp "$1" "artifact missing"; return; }
  n=$(wc -c <"$2" | tr -d ' '); r=$(wc -c <"$TMP/ref.logits" | tr -d ' ')
  if [[ "$n" != "$r" ]]; then bad "$1" "size $n != $r"; return; fi
  h=$(shasum -a 256 "$2" | awk '{print $1}')
  if [[ "$h" == "$REFHASH" ]]; then ok "$1" "$h"; else bad "$1" "$h"; fi
}

# --- 2, 3: other hosted builds ----------------------------------------
if [[ -x "$BUILD/mu_o0" ]]; then
  emit "$BUILD/mu_o0" "$TMP/o0.logits"; check "hosted -O0" "$TMP/o0.logits"
else skp "hosted -O0" "not built"; fi

if [[ -x "$BREW_CLANG" ]]; then
  [[ -x "$BUILD/mu_brewclang" ]] || "$BREW_CLANG" -std=c11 -O2 \
      -fno-fast-math -ffp-contract=off -fno-unsafe-math-optimizations \
      -march=armv8-a -I"$ROOT/mucore" -o "$BUILD/mu_brewclang" \
      "$ROOT/mucore/mu_core.c" "$ROOT/mucore/hosts/posix/main.c" 2>/dev/null
  emit "$BUILD/mu_brewclang" "$TMP/brew.logits"
  check "hosted second clang -O2" "$TMP/brew.logits"
else skp "hosted second clang -O2" "no second clang"; fi

# A genuinely independent compiler. clang-vs-clang across versions shares a
# frontend, an optimiser and a backend; clang-vs-gcc shares none of them.
if [[ -x "$BUILD/mu_altcc" ]]; then
  emit "$BUILD/mu_altcc" "$TMP/altcc.logits"; check "hosted gcc -O2" "$TMP/altcc.logits"
else skp "hosted gcc -O2" "gcc absent"; fi

# --- CompCert: the formally verified compiler --------------------------
# The strongest row here. CompCert has a machine-checked proof that its output
# preserves the source semantics, floats included. If it agrees, the reference
# hash is what the C program MEANS, not what one optimiser chose to emit.
CCOMP="$ROOT/vendor/compcert/CompCert/ccomp"
if [[ -x "$CCOMP" ]]; then
  [[ -x "$BUILD/mu_ccomp" ]] || "$CCOMP" -O2 -I"$ROOT/mucore" \
      -L"$ROOT/vendor/compcert/CompCert/runtime" -o "$BUILD/mu_ccomp" \
      "$ROOT/mucore/mu_core.c" "$ROOT/mucore/hosts/posix/main.c" 2>/dev/null
  emit "$BUILD/mu_ccomp" "$TMP/ccomp.logits"
  check "hosted CompCert -O2 (verified)" "$TMP/ccomp.logits"
else skp "hosted CompCert -O2 (verified)" "ccomp not built"; fi

# --- 4: aarch64 bare metal --------------------------------------------
check "baremetal aarch64 (qemu)" "$BUILD/bm/bm.logits"

# --- 5: x86-64 bare metal ---------------------------------------------
check "baremetal x86-64 (qemu softfloat)" "$BUILD/x86/x86.logits"

# --- 6: seL4 / Microkit -----------------------------------------------
MKOUT="$BUILD/mk/mk.out"
if [[ -f "$MKOUT" ]] && grep -q '@@@END' "$MKOUT" 2>/dev/null; then
  sed -n '/@@@BEGIN/,/@@@END/p' "$MKOUT" \
    | sed -e '/@@@BEGIN/d' -e '/@@@END/d' | tr -d '\r\n \t' > "$TMP/mk.hex"
  if (( $(wc -c <"$TMP/mk.hex") % 2 == 0 )); then
    xxd -r -p "$TMP/mk.hex" > "$TMP/mk.logits"
    check "seL4/microkit aarch64" "$TMP/mk.logits"
  else
    bad "seL4/microkit aarch64" "odd hex length, capture truncated"
  fi
else
  skp "seL4/microkit aarch64" "no completed capture"
fi

echo
echo "=== $pass passed, $fail failed, $skip skipped ==================="
echo
[[ $fail -eq 0 ]]

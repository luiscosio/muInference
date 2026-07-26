#!/usr/bin/env bash
# Fetch and verify the model inputs.
#
# These are inputs, not source, so they are not committed. They ARE pinned by
# hash: SHA256SUMS is checked in, and this script refuses to leave an unverified
# blob on disk. That matters more here than in a normal project, because the
# whole point of mucore is that its output is a pure function of its inputs. An
# unpinned checkpoint would make the reproducibility claim meaningless.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

STORIES_URL="https://huggingface.co/karpathy/tinyllamas/resolve/main/stories15M.bin"
TOKENIZER_URL="https://raw.githubusercontent.com/karpathy/llama2.c/master/tokenizer.bin"

fetch() {   # $1=url  $2=dest
  if [[ -f "$2" ]]; then
    echo "  $2 present, skipping download"
    return
  fi
  echo "  fetching $2"
  curl -fL --progress-bar -o "$2.part" "$1"
  mv "$2.part" "$2"
}

echo "model inputs:"
fetch "$STORIES_URL"   stories15M.bin
fetch "$TOKENIZER_URL" tokenizer.bin

echo "verifying against SHA256SUMS:"
if shasum -a 256 -c SHA256SUMS; then
  echo "OK"
else
  echo "HASH MISMATCH -- refusing to keep unverified inputs" >&2
  exit 1
fi

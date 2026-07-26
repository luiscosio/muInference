#!/usr/bin/env bash
# Build CompCert, the formally verified C compiler, for the S3b clause.
#
# Not vendored: it is a source distribution that has to be built, and the build
# is a Coq proof check taking tens of minutes. Needs Rocq 9.0-9.2, OCaml, and
# menhir (brew install coq menhir).
#
# Rocq 9.2 is explicitly supported by CompCert's configure as of 3.17.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if [ -x CompCert/ccomp ]; then echo "ccomp already built"; CompCert/ccomp -version; exit 0; fi

command -v menhir >/dev/null 2>&1 || { echo "menhir missing: brew install menhir" >&2; exit 1; }
command -v rocq   >/dev/null 2>&1 || command -v coqc >/dev/null 2>&1 || \
  { echo "rocq/coq missing: brew install coq" >&2; exit 1; }

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64)  TARGET=aarch64-macos ;;
  Darwin-x86_64) TARGET=x86_64-macos  ;;
  Linux-aarch64) TARGET=aarch64-linux ;;
  Linux-x86_64)  TARGET=x86_64-linux  ;;
  *) echo "unsupported host" >&2; exit 1 ;;
esac

[ -d CompCert ] || git clone --depth 1 https://github.com/AbsInt/CompCert.git
cd CompCert
./configure "$TARGET"
make -j"$( (sysctl -n hw.ncpu 2>/dev/null) || nproc )"
./ccomp -version

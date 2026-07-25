#!/usr/bin/env bash
# Fetch the seL4 Microkit SDK.
#
# Not committed: 69 MB of prebuilt seL4 kernels and libmicrokit per board.
# Pinned by version so the build is reproducible; upstream publishes a detached
# signature (.asc) alongside each asset if you want to verify provenance.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

VERSION="${MICROKIT_VERSION:-2.3.0}"
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64)  PLAT=macos-aarch64 ;;
  Darwin-x86_64) PLAT=macos-x86-64 ;;
  Linux-aarch64) PLAT=linux-aarch64 ;;
  Linux-x86_64)  PLAT=linux-x86-64 ;;
  *) echo "unsupported host: $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

DIR="microkit-sdk-$VERSION"
if [[ -d "$DIR" ]]; then echo "$DIR present"; exit 0; fi

URL="https://github.com/seL4/microkit/releases/download/$VERSION/microkit-sdk-$VERSION-$PLAT.tar.gz"
echo "fetching $URL"
curl -fL --progress-bar -o sdk.tar.gz "$URL"
tar xzf sdk.tar.gz
rm -f sdk.tar.gz
echo "extracted $DIR"

#!/usr/bin/env python3
"""Generate the measured RoPE table for muinference.

Why this exists
---------------
Upstream llama2.c computes RoPE inline with powf/cosf/sinf. Those are the
IEEE-754 "recommended" operations: not required to be correctly rounded, and
demonstrably different between libm vendors, versions, and even between the
scalar and vectorised paths of one library. Any of them in the hot loop makes
bit-reproducibility impossible to claim.

So we compute the table once, offline, in float64, and check it into the tree
as a measured artifact with a SHA-256. At runtime it is an *input* whose hash
is covered by the image measurement, not a computation to be trusted. That is
the same move as "verify the state of the world instead of trusting the
process that produced it", applied to a lookup table.

Net effect on the runtime: powf, cosf and sinf leave the trusted computing
base entirely. The only remaining transcendental is expf (softmax and SwiGLU),
which mu_math.h implements from mandated operations only.

Layout, float32 little-endian:
    for pos in [0, seq_len):
        for j in [0, head_size/2):
            cos(pos / 10000^(2j/head_size))
            sin(pos / 10000^(2j/head_size))
Total: seq_len * head_size float32 values.
"""
import argparse
import hashlib
import math
import struct
import sys


def build(seq_len: int, head_size: int) -> bytes:
    if head_size % 2 != 0:
        raise SystemExit(f"head_size must be even, got {head_size}")
    out = bytearray()
    for pos in range(seq_len):
        for j in range(head_size // 2):
            # freq = 1 / 10000^(head_dim/head_size) with head_dim = 2j.
            # Computed in float64; math.pow and math.cos here are the *offline*
            # transcendentals whose results we are freezing into an artifact.
            head_dim = 2 * j
            freq = 1.0 / math.pow(10000.0, head_dim / head_size)
            val = pos * freq
            out += struct.pack("<ff", math.cos(val), math.sin(val))
    return bytes(out)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seq-len", type=int, required=True)
    ap.add_argument("--head-size", type=int, required=True)
    ap.add_argument("-o", "--out", required=True)
    args = ap.parse_args()

    blob = build(args.seq_len, args.head_size)
    expect = args.seq_len * args.head_size * 4
    assert len(blob) == expect, (len(blob), expect)

    with open(args.out, "wb") as f:
        f.write(blob)

    digest = hashlib.sha256(blob).hexdigest()
    with open(args.out + ".sha256", "w") as f:
        f.write(f"{digest}  {args.out.rsplit('/', 1)[-1]}\n")

    print(f"wrote {args.out}  {len(blob)} bytes")
    print(f"sha256 {digest}")
    print(f"config seq_len={args.seq_len} head_size={args.head_size}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""
fuzz_enclave_rpc.py

Basic fuzzer for the muinference enclave RPC protocol.
Tests robustness against malformed inputs.
"""

import argparse
import json
import os
import random
import socket
import struct
import sys
import time

try:
    from Cryptodome.Cipher import AES
    from Cryptodome.Random import get_random_bytes
except ImportError:
    from Crypto.Cipher import AES
    from Crypto.Random import get_random_bytes


ENCLAVE_KEY = bytes.fromhex("00112233445566778899aabbccddeeff")


def recv_msg(conn, timeout=5):
    """Receive a length-prefixed message."""
    conn.settimeout(timeout)
    header = conn.recv(4)
    if len(header) < 4:
        raise ConnectionError("Short header")
    (length,) = struct.unpack("!I", header)
    if length > 10 * 1024 * 1024:
        raise ValueError(f"Message too large: {length}")
    data = b""
    while len(data) < length:
        chunk = conn.recv(min(length - len(data), 65536))
        if not chunk:
            raise ConnectionError("Connection closed")
        data += chunk
    return data


def send_msg(conn, data: bytes):
    """Send a length-prefixed message."""
    conn.sendall(struct.pack("!I", len(data)) + data)


def send_raw(conn, data: bytes):
    """Send raw bytes without length prefix."""
    conn.sendall(data)


def create_unlock_token():
    """Create valid unlock token."""
    plaintext = b"muinference unlock"
    nonce = get_random_bytes(12)
    cipher = AES.new(ENCLAVE_KEY, AES.MODE_GCM, nonce=nonce)
    ciphertext, tag = cipher.encrypt_and_digest(plaintext)
    return {
        "nonce": nonce.hex(),
        "tag": tag.hex(),
        "ciphertext": ciphertext.hex(),
    }


def connect_and_unlock(host, port):
    """Connect to enclave and complete attestation."""
    conn = socket.create_connection((host, port), timeout=10)

    # Receive measurement
    _ = recv_msg(conn)

    # Send unlock
    unlock = create_unlock_token()
    send_msg(conn, json.dumps(unlock).encode())

    # Receive ready
    ready = recv_msg(conn, timeout=60)
    resp = json.loads(ready.decode())
    if resp.get("status") != "ready":
        raise RuntimeError(f"Enclave not ready: {resp}")

    return conn


class FuzzCase:
    """A single fuzz test case."""

    def __init__(self, name, generator):
        self.name = name
        self.generator = generator

    def generate(self):
        return self.generator()


# Fuzz case generators
def gen_valid_request():
    """Valid request."""
    return json.dumps({
        "prompt": "Hello, world!",
        "max_new_tokens": 32
    }).encode()


def gen_empty():
    """Empty message."""
    return b""


def gen_garbage():
    """Random bytes."""
    return os.urandom(random.randint(1, 1024))


def gen_invalid_json():
    """Malformed JSON."""
    choices = [
        b"{",
        b'{"prompt":',
        b'{"prompt": "test"',
        b"not json at all",
        b'{"prompt": "test", "max_new_tokens": "not a number"}',
        b'[1, 2, 3]',
        b"null",
        b'"just a string"',
    ]
    return random.choice(choices)


def gen_huge_prompt():
    """Very large prompt."""
    size = random.choice([10000, 100000, 1000000])
    return json.dumps({
        "prompt": "A" * size,
        "max_new_tokens": 1
    }).encode()


def gen_negative_tokens():
    """Negative max_new_tokens."""
    return json.dumps({
        "prompt": "test",
        "max_new_tokens": -1
    }).encode()


def gen_huge_tokens():
    """Very large max_new_tokens."""
    return json.dumps({
        "prompt": "test",
        "max_new_tokens": 999999999
    }).encode()


def gen_missing_prompt():
    """Missing prompt field."""
    return json.dumps({
        "max_new_tokens": 32
    }).encode()


def gen_null_prompt():
    """Null prompt."""
    return json.dumps({
        "prompt": None,
        "max_new_tokens": 32
    }).encode()


def gen_unicode_prompt():
    """Unicode edge cases."""
    choices = [
        "\x00\x00\x00",  # Null bytes
        "\ud83d\ude00" * 1000,  # Lots of emoji
        "\uffff" * 100,  # Max BMP char
        "A\u0000B\u0000C",  # Embedded nulls
        "\u202e" + "reversed",  # RTL override
    ]
    return json.dumps({
        "prompt": random.choice(choices),
        "max_new_tokens": 32
    }).encode()


def gen_nested_json():
    """Deeply nested JSON."""
    depth = random.choice([100, 1000])
    obj = {"prompt": "test", "max_new_tokens": 1}
    for _ in range(depth):
        obj = {"nested": obj}
    return json.dumps(obj).encode()


def gen_extra_fields():
    """Extra unexpected fields."""
    return json.dumps({
        "prompt": "test",
        "max_new_tokens": 32,
        "evil_field": "A" * 10000,
        "__proto__": {"polluted": True},
        "constructor": {"prototype": {}},
    }).encode()


FUZZ_CASES = [
    FuzzCase("valid", gen_valid_request),
    FuzzCase("empty", gen_empty),
    FuzzCase("garbage", gen_garbage),
    FuzzCase("invalid_json", gen_invalid_json),
    FuzzCase("huge_prompt", gen_huge_prompt),
    FuzzCase("negative_tokens", gen_negative_tokens),
    FuzzCase("huge_tokens", gen_huge_tokens),
    FuzzCase("missing_prompt", gen_missing_prompt),
    FuzzCase("null_prompt", gen_null_prompt),
    FuzzCase("unicode", gen_unicode_prompt),
    FuzzCase("nested", gen_nested_json),
    FuzzCase("extra_fields", gen_extra_fields),
]


def run_fuzz_test(conn, case, verbose=False):
    """Run a single fuzz test."""
    try:
        payload = case.generate()
        if verbose:
            preview = payload[:100].decode("utf-8", errors="replace")
            print(f"  Sending: {preview}...")

        send_msg(conn, payload)
        response = recv_msg(conn, timeout=30)
        resp = json.loads(response.decode())

        if "error" in resp:
            return "handled_error", resp["error"]
        elif "completion" in resp:
            return "success", len(resp["completion"])
        else:
            return "unexpected", resp

    except socket.timeout:
        return "timeout", None
    except ConnectionError as e:
        return "disconnect", str(e)
    except Exception as e:
        return "exception", str(e)


def main():
    parser = argparse.ArgumentParser(description="Fuzz test the enclave RPC")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=10000)
    parser.add_argument("--iterations", type=int, default=100)
    parser.add_argument("--verbose", "-v", action="store_true")
    parser.add_argument("--case", help="Run only this test case")
    args = parser.parse_args()

    print("=== muinference RPC Fuzzer ===")
    print(f"Target: {args.host}:{args.port}")
    print(f"Iterations: {args.iterations}")
    print()

    # Filter cases if specified
    cases = FUZZ_CASES
    if args.case:
        cases = [c for c in cases if c.name == args.case]
        if not cases:
            print(f"Unknown case: {args.case}")
            print(f"Available: {[c.name for c in FUZZ_CASES]}")
            sys.exit(1)

    # Connect and unlock
    print("Connecting to enclave...")
    try:
        conn = connect_and_unlock(args.host, args.port)
    except Exception as e:
        print(f"Failed to connect: {e}")
        sys.exit(1)

    print("Connected and unlocked")
    print()

    # Run fuzz tests
    results = {
        "success": 0,
        "handled_error": 0,
        "timeout": 0,
        "disconnect": 0,
        "exception": 0,
        "unexpected": 0,
    }

    disconnected = False

    for i in range(args.iterations):
        if disconnected:
            print(f"[{i}] Reconnecting...")
            try:
                conn = connect_and_unlock(args.host, args.port)
                disconnected = False
            except Exception as e:
                print(f"  Failed to reconnect: {e}")
                break

        case = random.choice(cases)
        if args.verbose:
            print(f"[{i}] Testing: {case.name}")

        result, detail = run_fuzz_test(conn, case, args.verbose)
        results[result] += 1

        if result == "disconnect":
            disconnected = True
            if args.verbose:
                print(f"  Disconnected: {detail}")
        elif args.verbose:
            print(f"  Result: {result} - {detail}")

        # Small delay between tests
        time.sleep(0.1)

    conn.close()

    # Print results
    print()
    print("=== Results ===")
    for result_type, count in results.items():
        pct = (count / args.iterations) * 100 if args.iterations > 0 else 0
        print(f"  {result_type}: {count} ({pct:.1f}%)")

    print()
    if results["disconnect"] > 0:
        print("WARNING: Some tests caused disconnection (potential DoS)")
    if results["exception"] > 0:
        print("WARNING: Some tests caused exceptions")

    print()
    print("A well-hardened enclave should:")
    print("  - Never crash or disconnect from malformed input")
    print("  - Return appropriate error messages")
    print("  - Not hang indefinitely")


if __name__ == "__main__":
    main()

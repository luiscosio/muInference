#!/usr/bin/env python3
"""
host_proxy_and_attest.py

Host-side proxy for the muinference Weight Enclave.
Handles attestation, unlocking, and bandwidth-limited communication.

This implements the SL5 "physical bandwidth limitation on Weight Enclave
boundaries" control by rate-limiting output.
"""

import argparse
import json
import os
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


# Default configuration
DEFAULT_ENCLAVE_HOST = "127.0.0.1"
DEFAULT_ENCLAVE_PORT = 10000
DEFAULT_RATE_KB = 5  # KB/s - intentionally slow for weight exfil protection

# Shared key - in production, derive from secure key exchange
ENCLAVE_KEY = bytes.fromhex("00112233445566778899aabbccddeeff")


def recv_msg(conn, timeout=30):
    """Receive a length-prefixed message."""
    conn.settimeout(timeout)

    header = b""
    while len(header) < 4:
        chunk = conn.recv(4 - len(header))
        if not chunk:
            raise ConnectionError("Connection closed while reading header")
        header += chunk

    (length,) = struct.unpack("!I", header)

    if length > 100 * 1024 * 1024:  # 100MB max
        raise ValueError(f"Message too large: {length}")

    data = b""
    while len(data) < length:
        chunk = conn.recv(min(length - len(data), 65536))
        if not chunk:
            raise ConnectionError("Connection closed while reading data")
        data += chunk

    return data


def send_msg(conn, data: bytes):
    """Send a length-prefixed message."""
    conn.sendall(struct.pack("!I", len(data)) + data)


def create_unlock_token():
    """Create an encrypted unlock token for the enclave."""
    plaintext = b"muinference unlock token " + str(int(time.time())).encode()
    nonce = get_random_bytes(12)
    cipher = AES.new(ENCLAVE_KEY, AES.MODE_GCM, nonce=nonce)
    ciphertext, tag = cipher.encrypt_and_digest(plaintext)

    return {
        "nonce": nonce.hex(),
        "tag": tag.hex(),
        "ciphertext": ciphertext.hex(),
    }


def rate_limited_print(text, rate_kb):
    """Print text with bandwidth limiting to simulate exfil protection."""
    max_bytes_per_sec = rate_kb * 1024
    chunk_size = 64  # characters per chunk
    sent = 0
    t_start = time.time()

    for i in range(0, len(text), chunk_size):
        now = time.time()
        elapsed = now - t_start
        allowed = max_bytes_per_sec * max(elapsed, 0.001)

        if sent > allowed:
            sleep_time = (sent - allowed) / max_bytes_per_sec
            time.sleep(sleep_time)

        chunk = text[i:i + chunk_size]
        sent += len(chunk.encode("utf-8"))
        print(chunk, end="", flush=True)

    print()  # Final newline


def connect_and_attest(host, port, expected_measurement=None):
    """Connect to enclave and perform attestation."""
    print(f"[host] Connecting to enclave at {host}:{port}...")

    try:
        conn = socket.create_connection((host, port), timeout=10)
    except Exception as e:
        print(f"[host] Failed to connect: {e}")
        return None

    print("[host] Connected, waiting for attestation...")

    # Receive measurement
    try:
        att_bytes = recv_msg(conn)
        att = json.loads(att_bytes.decode())
    except Exception as e:
        print(f"[host] Failed to receive attestation: {e}")
        conn.close()
        return None

    measurement = att.get("measurement", "")
    print(f"[host] Enclave measurement: {measurement}")

    # Verify measurement if expected value provided
    if expected_measurement:
        if measurement != expected_measurement:
            print(f"[host] ERROR: Measurement mismatch!")
            print(f"[host] Expected: {expected_measurement}")
            print(f"[host] Got:      {measurement}")
            conn.close()
            return None
        print("[host] Measurement verified!")
    else:
        print("[host] WARNING: No expected measurement configured, accepting any")

    # Send unlock token
    print("[host] Sending unlock token...")
    unlock = create_unlock_token()
    send_msg(conn, json.dumps(unlock).encode())

    # Wait for ready signal
    try:
        ready_bytes = recv_msg(conn, timeout=120)  # Model loading may take time
        ready = json.loads(ready_bytes.decode())
    except Exception as e:
        print(f"[host] Failed to receive ready signal: {e}")
        conn.close()
        return None

    if ready.get("status") != "ready":
        print(f"[host] Enclave not ready: {ready}")
        conn.close()
        return None

    print("[host] Enclave ready for inference!")
    return conn


def inference_loop(conn, rate_kb):
    """Interactive inference loop."""
    print()
    print("=" * 60)
    print("muinference Weight Enclave - Interactive Mode")
    print(f"Output rate limited to {rate_kb} KB/s")
    print("Type your prompts, Ctrl+D or 'quit' to exit")
    print("=" * 60)
    print()

    while True:
        try:
            prompt = input("prompt> ").strip()
        except EOFError:
            print("\n[host] EOF received, exiting")
            break
        except KeyboardInterrupt:
            print("\n[host] Interrupted, exiting")
            break

        if not prompt:
            continue

        if prompt.lower() in ("quit", "exit", "q"):
            print("[host] Exiting...")
            break

        # Parse optional max_tokens from prompt
        max_tokens = 128
        if prompt.startswith("/tokens "):
            parts = prompt.split(" ", 2)
            if len(parts) >= 3:
                try:
                    max_tokens = int(parts[1])
                    prompt = parts[2]
                except ValueError:
                    pass

        # Send request
        request = {
            "prompt": prompt,
            "max_new_tokens": max_tokens
        }

        try:
            send_msg(conn, json.dumps(request).encode())
        except Exception as e:
            print(f"[host] Failed to send request: {e}")
            break

        # Receive response
        try:
            resp_bytes = recv_msg(conn, timeout=300)  # 5 min timeout for generation
            resp = json.loads(resp_bytes.decode())
        except Exception as e:
            print(f"[host] Failed to receive response: {e}")
            break

        if "error" in resp:
            print(f"[host] Error: {resp['error']}")
            continue

        completion = resp.get("completion", "")
        elapsed_ms = resp.get("elapsed_ms", 0)

        print()
        print(f"[{elapsed_ms}ms] ", end="")
        rate_limited_print(completion, rate_kb)
        print()


def batch_mode(conn, prompts_file, output_file, rate_kb):
    """Process prompts from a file."""
    with open(prompts_file, "r") as f:
        prompts = [line.strip() for line in f if line.strip()]

    results = []

    for i, prompt in enumerate(prompts):
        print(f"[host] Processing {i + 1}/{len(prompts)}: {prompt[:50]}...")

        request = {"prompt": prompt, "max_new_tokens": 128}
        send_msg(conn, json.dumps(request).encode())

        resp_bytes = recv_msg(conn, timeout=300)
        resp = json.loads(resp_bytes.decode())

        results.append({
            "prompt": prompt,
            "completion": resp.get("completion", ""),
            "error": resp.get("error"),
            "elapsed_ms": resp.get("elapsed_ms", 0)
        })

    if output_file:
        with open(output_file, "w") as f:
            json.dump(results, f, indent=2)
        print(f"[host] Results written to {output_file}")
    else:
        for r in results:
            print(f"\n--- Prompt: {r['prompt'][:50]}...")
            if r["error"]:
                print(f"Error: {r['error']}")
            else:
                rate_limited_print(r["completion"], rate_kb)


def main():
    parser = argparse.ArgumentParser(
        description="Host proxy for muinference Weight Enclave"
    )
    parser.add_argument(
        "--host",
        default=DEFAULT_ENCLAVE_HOST,
        help=f"Enclave host (default: {DEFAULT_ENCLAVE_HOST})"
    )
    parser.add_argument(
        "--port",
        type=int,
        default=DEFAULT_ENCLAVE_PORT,
        help=f"Enclave port (default: {DEFAULT_ENCLAVE_PORT})"
    )
    parser.add_argument(
        "--rate-kb",
        type=int,
        default=DEFAULT_RATE_KB,
        help=f"Max output rate in KB/s (default: {DEFAULT_RATE_KB})"
    )
    parser.add_argument(
        "--expected-measurement",
        default=os.environ.get("MU_ENCLAVE_MEASUREMENT"),
        help="Expected enclave measurement hash (or set MU_ENCLAVE_MEASUREMENT env)"
    )
    parser.add_argument(
        "--prompts-file",
        help="File containing prompts (one per line) for batch mode"
    )
    parser.add_argument(
        "--output-file",
        help="Output file for batch results (JSON)"
    )

    args = parser.parse_args()

    # Connect and attest
    conn = connect_and_attest(
        args.host,
        args.port,
        args.expected_measurement
    )

    if not conn:
        sys.exit(1)

    try:
        if args.prompts_file:
            batch_mode(conn, args.prompts_file, args.output_file, args.rate_kb)
        else:
            inference_loop(conn, args.rate_kb)
    finally:
        conn.close()
        print("[host] Connection closed")


if __name__ == "__main__":
    main()

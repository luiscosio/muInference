#!/usr/bin/env python3
"""
End-to-end test for muinference.

Runs the enclave server as a subprocess and tests the full protocol
including attestation, unlock, and inference.
"""

import json
import os
import socket
import struct
import subprocess
import sys
import time
import threading

# Add parent directories to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'scripts'))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'external', 'muinference', 'rootfs_overlay', 'opt'))

from Crypto.Cipher import AES
from Crypto.Random import get_random_bytes

ENCLAVE_KEY = bytes.fromhex("00112233445566778899aabbccddeeff")
TEST_PORT = 19999


def send_msg(conn, data: bytes):
    """Send a length-prefixed message."""
    conn.sendall(struct.pack("!I", len(data)) + data)


def recv_msg(conn, timeout=60):
    """Receive a length-prefixed message."""
    conn.settimeout(timeout)
    header = b""
    while len(header) < 4:
        chunk = conn.recv(4 - len(header))
        if not chunk:
            raise ConnectionError("Connection closed while reading header")
        header += chunk

    (length,) = struct.unpack("!I", header)

    if length > 100 * 1024 * 1024:
        raise ValueError(f"Message too large: {length}")

    data = b""
    while len(data) < length:
        chunk = conn.recv(min(length - len(data), 65536))
        if not chunk:
            raise ConnectionError("Connection closed while reading data")
        data += chunk

    return data


def create_unlock_token():
    """Create an encrypted unlock token."""
    plaintext = b"muinference e2e test unlock"
    nonce = get_random_bytes(12)
    cipher = AES.new(ENCLAVE_KEY, AES.MODE_GCM, nonce=nonce)
    ciphertext, tag = cipher.encrypt_and_digest(plaintext)
    return {
        "nonce": nonce.hex(),
        "tag": tag.hex(),
        "ciphertext": ciphertext.hex(),
    }


def test_enclave_protocol(port, skip_inference=False):
    """Test the full enclave protocol."""
    print(f"\n{'='*60}")
    print("Testing Enclave Protocol")
    print(f"{'='*60}\n")

    # Connect
    print(f"1. Connecting to localhost:{port}...")
    conn = socket.create_connection(("127.0.0.1", port), timeout=10)
    print("   Connected!")

    # Receive attestation
    print("\n2. Receiving attestation measurement...")
    att_bytes = recv_msg(conn, timeout=30)
    att = json.loads(att_bytes.decode())
    measurement = att.get("measurement", "")
    print(f"   Measurement: {measurement[:32]}...")
    print(f"   Length: {len(measurement)} chars")
    assert len(measurement) == 64, "Invalid measurement length"
    print("   Attestation: OK")

    # Send unlock token
    print("\n3. Sending encrypted unlock token...")
    unlock = create_unlock_token()
    send_msg(conn, json.dumps(unlock).encode())
    print("   Token sent!")

    # Receive ready
    print("\n4. Waiting for ready signal...")
    ready_bytes = recv_msg(conn, timeout=120)  # Model loading can take time
    ready = json.loads(ready_bytes.decode())
    print(f"   Response: {ready}")
    assert ready.get("status") == "ready", f"Enclave not ready: {ready}"
    print("   Enclave ready!")

    if skip_inference:
        print("\n5. Skipping inference test (skip_inference=True)")
        conn.close()
        return True

    # Test inference
    print("\n5. Testing inference...")
    prompts = [
        ("What is 2+2?", 32),
        ("Say hello in one word.", 16),
    ]

    for prompt, max_tokens in prompts:
        print(f"\n   Prompt: '{prompt}'")
        req = {"prompt": prompt, "max_new_tokens": max_tokens}
        send_msg(conn, json.dumps(req).encode())

        resp_bytes = recv_msg(conn, timeout=120)
        resp = json.loads(resp_bytes.decode())

        if "error" in resp:
            print(f"   Error: {resp['error']}")
        else:
            completion = resp.get("completion", "")
            elapsed = resp.get("elapsed_ms", 0)
            print(f"   Response: {completion[:100]}{'...' if len(completion) > 100 else ''}")
            print(f"   Elapsed: {elapsed}ms")

    conn.close()
    print("\n" + "="*60)
    print("E2E Test: PASSED")
    print("="*60)
    return True


def run_enclave_server(port):
    """Run the enclave server as a subprocess."""
    script_path = os.path.join(
        os.path.dirname(__file__),
        '..',
        'external',
        'muinference',
        'rootfs_overlay',
        'opt',
        'enclave_server.py'
    )

    env = os.environ.copy()
    env['ENCLAVE_PORT'] = str(port)

    proc = subprocess.Popen(
        [sys.executable, script_path],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True
    )

    return proc


def main():
    import argparse
    parser = argparse.ArgumentParser(description="E2E test for muinference")
    parser.add_argument("--port", type=int, default=TEST_PORT, help="Port to use")
    parser.add_argument("--skip-inference", action="store_true", help="Skip actual inference")
    parser.add_argument("--external", action="store_true", help="Connect to external server (don't start one)")
    args = parser.parse_args()

    if args.external:
        # Just connect to existing server
        test_enclave_protocol(args.port, args.skip_inference)
    else:
        # Start server and test
        print("Starting enclave server...")
        proc = run_enclave_server(args.port)

        # Wait for server to start
        time.sleep(2)

        # Read initial output
        def read_output(proc):
            for line in proc.stdout:
                print(f"[enclave] {line.rstrip()}")

        output_thread = threading.Thread(target=read_output, args=(proc,), daemon=True)
        output_thread.start()

        time.sleep(1)

        try:
            success = test_enclave_protocol(args.port, args.skip_inference)
        finally:
            print("\nStopping enclave server...")
            proc.terminate()
            proc.wait(timeout=5)

        return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())

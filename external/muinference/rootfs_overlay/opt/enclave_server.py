#!/usr/bin/env python3
"""
muinference Weight Enclave Server

SL5-style minimal inference server that runs inside a Buildroot-based
micro-enclave. The host is treated as untrusted; only this server handles
model weights.

Model: Llama-3.2-3B-Instruct (unsloth/Llama-3.2-3B-Instruct)
https://huggingface.co/unsloth/Llama-3.2-3B-Instruct

Protocol:
1. Server sends measurement (hash of server code + kernel version)
2. Host sends encrypted unlock token (AES-GCM)
3. Server decrypts and loads model
4. Host sends inference requests, server responds with completions
"""

import hashlib
import json
import os
import socket
import struct
import sys
import time

try:
    from Cryptodome.Cipher import AES
except ImportError:
    from Crypto.Cipher import AES

# Configuration - in production, derive from TPM/secure boot
ENCLAVE_KEY = bytes.fromhex("00112233445566778899aabbccddeeff")
MODEL_ID = "unsloth/Llama-3.2-3B-Instruct"
MODEL_NAME_OR_PATH = os.environ.get("MODEL_PATH", MODEL_ID)
LISTEN_PORT = int(os.environ.get("ENCLAVE_PORT", "9000"))

# Llama 3.2 chat template
LLAMA_SYSTEM_PROMPT = """You are a helpful AI assistant running inside a secure weight enclave."""


def compute_measurement():
    """
    Compute a measurement hash of this enclave's identity.
    In production, this would come from TPM PCRs or secure boot chain.
    """
    h = hashlib.sha256()

    # Hash the server code itself
    try:
        with open(__file__, "rb") as f:
            h.update(f.read())
    except Exception:
        h.update(b"enclave_server")

    # Include kernel version
    try:
        h.update(os.uname().release.encode())
    except Exception:
        h.update(b"unknown_kernel")

    # Include config file if present
    try:
        with open("/etc/muinference.conf", "rb") as f:
            h.update(f.read())
    except Exception:
        pass

    return h.hexdigest()


def recv_msg(conn):
    """Receive a length-prefixed message."""
    header = b""
    while len(header) < 4:
        chunk = conn.recv(4 - len(header))
        if not chunk:
            raise ConnectionError("Connection closed while reading header")
        header += chunk

    (length,) = struct.unpack("!I", header)

    if length > 100 * 1024 * 1024:  # 100MB max message
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


def load_model(device):
    """
    Load Llama-3.2-3B-Instruct model.
    Returns (model, tokenizer) or (None, None) for demo mode.
    """
    try:
        import torch
        from transformers import AutoModelForCausalLM, AutoTokenizer

        print(f"[enclave] Loading model: {MODEL_NAME_OR_PATH}", flush=True)
        print(f"[enclave] Target device: {device}", flush=True)

        # Load tokenizer
        tokenizer = AutoTokenizer.from_pretrained(
            MODEL_NAME_OR_PATH,
            trust_remote_code=True
        )

        # Ensure pad token is set (Llama uses eos as pad)
        if tokenizer.pad_token is None:
            tokenizer.pad_token = tokenizer.eos_token

        # Load model with appropriate settings for Llama 3.2 3B
        model = AutoModelForCausalLM.from_pretrained(
            MODEL_NAME_OR_PATH,
            torch_dtype=torch.bfloat16 if device == "cuda" else torch.float32,
            device_map="auto" if device == "cuda" else None,
            low_cpu_mem_usage=True,
            trust_remote_code=True
        )

        if device == "cpu":
            model = model.to(device)

        model.eval()

        # Print model info
        param_count = sum(p.numel() for p in model.parameters()) / 1e9
        print(f"[enclave] Model loaded: {param_count:.1f}B parameters", flush=True)
        print(f"[enclave] Model dtype: {model.dtype}", flush=True)

        return model, tokenizer

    except ImportError as e:
        print(f"[enclave] PyTorch/transformers not available: {e}", flush=True)
        print("[enclave] Running in demo mode (echo server)", flush=True)
        return None, None
    except Exception as e:
        print(f"[enclave] Failed to load model: {e}", flush=True)
        import traceback
        traceback.print_exc()
        print("[enclave] Running in demo mode (echo server)", flush=True)
        return None, None


def format_chat_prompt(user_message, system_prompt=None):
    """
    Format prompt using Llama 3.2 Instruct chat template.
    """
    if system_prompt is None:
        system_prompt = LLAMA_SYSTEM_PROMPT

    # Llama 3.2 Instruct format
    formatted = f"""<|begin_of_text|><|start_header_id|>system<|end_header_id|>

{system_prompt}<|eot_id|><|start_header_id|>user<|end_header_id|>

{user_message}<|eot_id|><|start_header_id|>assistant<|end_header_id|>

"""
    return formatted


def generate_response(model, tokenizer, prompt, max_new_tokens, device, use_chat_template=True):
    """Generate a response using Llama-3.2-3B-Instruct."""
    if model is None or tokenizer is None:
        # Demo mode: echo the prompt with a prefix
        return f"[DEMO MODE] Echo: {prompt}"

    import torch

    # Format with chat template for instruct model
    if use_chat_template:
        formatted_prompt = format_chat_prompt(prompt)
    else:
        formatted_prompt = prompt

    inputs = tokenizer(formatted_prompt, return_tensors="pt", add_special_tokens=False)

    if device == "cuda":
        inputs = {k: v.cuda() for k, v in inputs.items()}
    else:
        inputs = {k: v.to(device) for k, v in inputs.items()}

    # Generation config optimized for Llama 3.2
    with torch.no_grad():
        outputs = model.generate(
            **inputs,
            max_new_tokens=max_new_tokens,
            do_sample=True,
            temperature=0.7,
            top_p=0.9,
            top_k=50,
            repetition_penalty=1.1,
            pad_token_id=tokenizer.pad_token_id,
            eos_token_id=tokenizer.eos_token_id,
        )

    # Decode only the new tokens (assistant response)
    input_length = inputs["input_ids"].shape[1]
    generated_tokens = outputs[0][input_length:]
    response = tokenizer.decode(generated_tokens, skip_special_tokens=True)

    return response.strip()


def main():
    print("[enclave] muinference Weight Enclave starting...", flush=True)

    # Determine device
    try:
        import torch
        device = "cuda" if torch.cuda.is_available() else "cpu"
        print(f"[enclave] PyTorch device: {device}", flush=True)
        if device == "cuda":
            print(f"[enclave] GPU: {torch.cuda.get_device_name(0)}", flush=True)
    except ImportError:
        device = "cpu"
        print("[enclave] PyTorch not available, using demo mode", flush=True)

    # Create listening socket
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("0.0.0.0", LISTEN_PORT))
    server.listen(1)

    print(f"[enclave] Listening on 0.0.0.0:{LISTEN_PORT}", flush=True)

    while True:
        conn, addr = server.accept()
        print(f"[enclave] Host connected from {addr}", flush=True)

        try:
            handle_connection(conn, device)
        except Exception as e:
            print(f"[enclave] Connection error: {e}", flush=True)
        finally:
            conn.close()
            print("[enclave] Connection closed, waiting for new connection...", flush=True)


def handle_connection(conn, device):
    """Handle a single host connection."""

    # Step 1: Send measurement for attestation
    measurement = compute_measurement()
    print(f"[enclave] Measurement: {measurement}", flush=True)
    send_msg(conn, json.dumps({"measurement": measurement}).encode())

    # Step 2: Receive and verify encrypted unlock token
    try:
        blob = recv_msg(conn)
        enc = json.loads(blob.decode())

        nonce = bytes.fromhex(enc["nonce"])
        tag = bytes.fromhex(enc["tag"])
        ciphertext = bytes.fromhex(enc["ciphertext"])

        cipher = AES.new(ENCLAVE_KEY, AES.MODE_GCM, nonce=nonce)
        plaintext = cipher.decrypt_and_verify(ciphertext, tag)

        print(f"[enclave] Unlock token verified: {plaintext.decode()}", flush=True)

    except Exception as e:
        print(f"[enclave] Attestation failed: {e}", flush=True)
        send_msg(conn, json.dumps({"error": "attestation_failed"}).encode())
        return

    # Step 3: Load model
    print("[enclave] Attestation successful, loading model...", flush=True)
    model, tokenizer = load_model(device)

    # Send ready signal
    send_msg(conn, json.dumps({"status": "ready"}).encode())

    # Step 4: Handle inference requests
    print("[enclave] Ready for inference requests", flush=True)

    while True:
        try:
            req_bytes = recv_msg(conn)
        except ConnectionError:
            print("[enclave] Host disconnected", flush=True)
            break
        except Exception as e:
            print(f"[enclave] Error receiving request: {e}", flush=True)
            break

        try:
            req = json.loads(req_bytes.decode())
        except json.JSONDecodeError as e:
            send_msg(conn, json.dumps({"error": f"invalid_json: {e}"}).encode())
            continue

        prompt = req.get("prompt", "")
        max_new_tokens = int(req.get("max_new_tokens", 64))

        # Clamp max tokens for safety
        max_new_tokens = min(max_new_tokens, 2048)

        print(f"[enclave] Generating response for prompt ({len(prompt)} chars)", flush=True)

        try:
            t_start = time.time()
            completion = generate_response(model, tokenizer, prompt, max_new_tokens, device)
            t_elapsed = time.time() - t_start

            print(f"[enclave] Generated {len(completion)} chars in {t_elapsed:.2f}s", flush=True)

            send_msg(conn, json.dumps({
                "completion": completion,
                "elapsed_ms": int(t_elapsed * 1000)
            }).encode())

        except Exception as e:
            print(f"[enclave] Generation error: {e}", flush=True)
            send_msg(conn, json.dumps({"error": str(e)}).encode())


if __name__ == "__main__":
    main()

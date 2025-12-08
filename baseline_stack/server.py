#!/usr/bin/env python3
"""
Baseline inference server for comparison with muinference.

Model: Llama-3.2-3B-Instruct (unsloth/Llama-3.2-3B-Instruct)
https://huggingface.co/unsloth/Llama-3.2-3B-Instruct

This is a standard Flask-based inference API representing
a typical deployment without Weight Enclave protections.
"""

import json
import os
import time
from flask import Flask, request, jsonify

app = Flask(__name__)

# Global model (lazy loaded)
model = None
tokenizer = None
device = None

MODEL_ID = "unsloth/Llama-3.2-3B-Instruct"
MODEL_PATH = os.environ.get("MODEL_PATH", MODEL_ID)

# Llama 3.2 chat template
LLAMA_SYSTEM_PROMPT = """You are a helpful AI assistant."""


def format_chat_prompt(user_message, system_prompt=None):
    """Format prompt using Llama 3.2 Instruct chat template."""
    if system_prompt is None:
        system_prompt = LLAMA_SYSTEM_PROMPT

    formatted = f"""<|begin_of_text|><|start_header_id|>system<|end_header_id|>

{system_prompt}<|eot_id|><|start_header_id|>user<|end_header_id|>

{user_message}<|eot_id|><|start_header_id|>assistant<|end_header_id|>

"""
    return formatted


def load_model():
    """Load Llama-3.2-3B-Instruct model (lazy initialization)."""
    global model, tokenizer, device

    if model is not None:
        return

    try:
        import torch
        from transformers import AutoModelForCausalLM, AutoTokenizer

        device = "cuda" if torch.cuda.is_available() else "cpu"
        print(f"Loading model: {MODEL_PATH}")
        print(f"Device: {device}")

        tokenizer = AutoTokenizer.from_pretrained(
            MODEL_PATH,
            trust_remote_code=True
        )

        if tokenizer.pad_token is None:
            tokenizer.pad_token = tokenizer.eos_token

        model = AutoModelForCausalLM.from_pretrained(
            MODEL_PATH,
            torch_dtype=torch.bfloat16 if device == "cuda" else torch.float32,
            device_map="auto" if device == "cuda" else None,
            low_cpu_mem_usage=True,
            trust_remote_code=True
        )

        if device == "cpu":
            model = model.to(device)

        model.eval()

        param_count = sum(p.numel() for p in model.parameters()) / 1e9
        print(f"Model loaded: {param_count:.1f}B parameters")

    except Exception as e:
        print(f"Failed to load model: {e}")
        import traceback
        traceback.print_exc()
        print("Running in demo mode")


def generate_completion(prompt, max_new_tokens, use_chat_template=True):
    """Generate completion using Llama-3.2-3B-Instruct."""
    global model, tokenizer, device

    if model is None or tokenizer is None:
        return f"[DEMO MODE] Echo: {prompt}"

    import torch

    if use_chat_template:
        formatted_prompt = format_chat_prompt(prompt)
    else:
        formatted_prompt = prompt

    inputs = tokenizer(formatted_prompt, return_tensors="pt", add_special_tokens=False)

    if device == "cuda":
        inputs = {k: v.cuda() for k, v in inputs.items()}
    else:
        inputs = {k: v.to(device) for k, v in inputs.items()}

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

    input_length = inputs["input_ids"].shape[1]
    generated_tokens = outputs[0][input_length:]
    response = tokenizer.decode(generated_tokens, skip_special_tokens=True)

    return response.strip()


@app.route("/health", methods=["GET"])
def health():
    """Health check endpoint."""
    return jsonify({"status": "healthy"})


@app.route("/info", methods=["GET"])
def info():
    """Server info endpoint."""
    import platform
    return jsonify({
        "server": "baseline-inference",
        "model": MODEL_ID,
        "model_path": MODEL_PATH,
        "device": device or "not loaded",
        "python_version": platform.python_version(),
        "platform": platform.platform(),
    })


@app.route("/generate", methods=["POST"])
def generate():
    """Generate completion for a prompt."""
    load_model()

    data = request.get_json()
    if not data:
        return jsonify({"error": "No JSON body"}), 400

    prompt = data.get("prompt", "")
    max_new_tokens = int(data.get("max_new_tokens", 64))
    use_chat_template = data.get("use_chat_template", True)

    if not prompt:
        return jsonify({"error": "Missing prompt"}), 400

    max_new_tokens = min(max_new_tokens, 2048)

    t_start = time.time()

    try:
        completion = generate_completion(prompt, max_new_tokens, use_chat_template)
    except Exception as e:
        return jsonify({"error": str(e)}), 500

    elapsed_ms = int((time.time() - t_start) * 1000)

    return jsonify({
        "completion": completion,
        "elapsed_ms": elapsed_ms
    })


@app.route("/v1/chat/completions", methods=["POST"])
def chat_completions():
    """OpenAI-compatible chat completions endpoint."""
    load_model()

    data = request.get_json()
    if not data:
        return jsonify({"error": "No JSON body"}), 400

    messages = data.get("messages", [])
    max_tokens = int(data.get("max_tokens", 64))

    if not messages:
        return jsonify({"error": "Missing messages"}), 400

    # Extract last user message
    user_message = ""
    system_message = LLAMA_SYSTEM_PROMPT
    for msg in messages:
        if msg.get("role") == "user":
            user_message = msg.get("content", "")
        elif msg.get("role") == "system":
            system_message = msg.get("content", "")

    formatted_prompt = format_chat_prompt(user_message, system_message)

    t_start = time.time()
    completion = generate_completion(user_message, max_tokens, use_chat_template=True)
    elapsed_ms = int((time.time() - t_start) * 1000)

    return jsonify({
        "id": f"chatcmpl-{int(time.time())}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": MODEL_ID,
        "choices": [{
            "index": 0,
            "message": {
                "role": "assistant",
                "content": completion
            },
            "finish_reason": "stop"
        }],
        "usage": {
            "prompt_tokens": len(user_message.split()),
            "completion_tokens": len(completion.split()),
            "total_tokens": len(user_message.split()) + len(completion.split())
        }
    })


@app.route("/v1/completions", methods=["POST"])
def completions():
    """OpenAI-compatible completions endpoint."""
    load_model()

    data = request.get_json()
    if not data:
        return jsonify({"error": "No JSON body"}), 400

    prompt = data.get("prompt", "")
    max_tokens = int(data.get("max_tokens", 64))

    t_start = time.time()
    completion = generate_completion(prompt, max_tokens, use_chat_template=False)
    elapsed_ms = int((time.time() - t_start) * 1000)

    return jsonify({
        "id": f"cmpl-{int(time.time())}",
        "object": "text_completion",
        "created": int(time.time()),
        "model": MODEL_ID,
        "choices": [{
            "text": completion,
            "index": 0,
            "finish_reason": "length"
        }],
        "usage": {
            "prompt_tokens": len(prompt.split()),
            "completion_tokens": len(completion.split()),
            "total_tokens": len(prompt.split()) + len(completion.split())
        }
    })


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8000))
    debug = os.environ.get("DEBUG", "false").lower() == "true"

    print(f"Starting baseline inference server on port {port}")
    print(f"Model: {MODEL_ID}")

    if os.environ.get("PRELOAD_MODEL", "false").lower() == "true":
        load_model()

    app.run(host="0.0.0.0", port=port, debug=debug)

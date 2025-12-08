#!/usr/bin/env python3
"""
exfil_timing_test.py

Demonstrate that the bandwidth-limited proxy makes weight exfiltration
impractical. This is a key SL5 control.
"""

import argparse


def format_time(seconds):
    """Format seconds into human-readable time."""
    if seconds < 60:
        return f"{seconds:.1f} seconds"
    elif seconds < 3600:
        return f"{seconds / 60:.1f} minutes"
    elif seconds < 86400:
        return f"{seconds / 3600:.1f} hours"
    elif seconds < 31536000:
        return f"{seconds / 86400:.1f} days"
    else:
        return f"{seconds / 31536000:.1f} years"


def format_size(bytes_val):
    """Format bytes into human-readable size."""
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if bytes_val < 1024:
            return f"{bytes_val:.1f} {unit}"
        bytes_val /= 1024
    return f"{bytes_val:.1f} PB"


def calculate_exfil_time(model_size_gb, rate_kbps):
    """Calculate time to exfiltrate model at given rate."""
    model_bytes = model_size_gb * 1024 * 1024 * 1024
    rate_bytes_per_sec = rate_kbps * 1024
    return model_bytes / rate_bytes_per_sec


def main():
    parser = argparse.ArgumentParser(
        description="Calculate model weight exfiltration times"
    )
    parser.add_argument(
        "--rate-kb",
        type=float,
        default=5,
        help="Bandwidth limit in KB/s (default: 5)"
    )
    args = parser.parse_args()

    # Model sizes (approximate)
    models = [
        ("Llama-3.2-3B-Instruct (BF16)", 6),  # 3B params * 2 bytes
        ("Llama-3.2-3B-Instruct (INT8)", 3),  # 3B params * 1 byte
        ("LLaMA-7B (FP16)", 14),
        ("LLaMA-13B (FP16)", 26),
        ("LLaMA-70B (FP16)", 140),
        ("GPT-3 175B (FP16)", 350),
        ("Hypothetical 1T model", 2000),
    ]

    # Rates to compare
    rates = [
        ("muinference (5 KB/s)", 5),
        ("Slow dial-up (56 kbps)", 7),
        ("DSL (1 Mbps)", 125),
        ("Fast broadband (100 Mbps)", 12500),
        ("Datacenter (10 Gbps)", 1250000),
    ]

    print("=" * 70)
    print("Weight Exfiltration Time Analysis")
    print("=" * 70)
    print()
    print("This demonstrates why bandwidth limiting is a critical SL5 control.")
    print("Even with host compromise, weight exfil becomes impractical.")
    print()

    print("-" * 70)
    print(f"At muinference rate limit: {args.rate_kb} KB/s")
    print("-" * 70)
    print()

    for model_name, size_gb in models:
        time_sec = calculate_exfil_time(size_gb, args.rate_kb)
        print(f"{model_name}:")
        print(f"  Size: {format_size(size_gb * 1024 * 1024 * 1024)}")
        print(f"  Exfil time: {format_time(time_sec)}")
        print()

    print("-" * 70)
    print("Comparison: Llama-3.2-3B-Instruct exfil time at different rates")
    print("-" * 70)
    print()

    target_model = ("Llama-3.2-3B-Instruct (BF16)", 6)
    model_name, size_gb = target_model

    for rate_name, rate_kb in rates:
        time_sec = calculate_exfil_time(size_gb, rate_kb)
        print(f"{rate_name}:")
        print(f"  Rate: {format_size(rate_kb * 1024)}/s")
        print(f"  Time: {format_time(time_sec)}")
        print()

    print("-" * 70)
    print("Implications")
    print("-" * 70)
    print()
    print("At 5 KB/s (muinference default):")
    print()

    gpt20_time = calculate_exfil_time(40, 5)
    print(f"  - gpt-oss-20b would take {format_time(gpt20_time)} to exfiltrate")
    print(f"  - That's {gpt20_time / 86400:.0f} days of continuous transfer")
    print(f"  - Detection is highly likely during this window")
    print()

    llama3_time = calculate_exfil_time(6, 5)
    print(f"  - Llama-3.2-3B-Instruct would take {format_time(llama3_time)} to exfiltrate")
    print(f"  - That's {llama3_time / 86400:.1f} days of continuous transfer")
    print(f"  - Detection is highly likely during this window")
    print()

    print("Key SL5 benefits:")
    print("  1. Makes real-time weight theft impractical")
    print("  2. Provides extended detection window")
    print("  3. Inference responses (tokens) pass through quickly")
    print("  4. Only bulk data (weights) is rate-limited")
    print()
    print("This bandwidth control, combined with attestation and minimal OS,")
    print("implements the SL5 Weight Enclave security model.")


if __name__ == "__main__":
    main()

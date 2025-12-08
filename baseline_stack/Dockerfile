# Baseline GPU Inference Stack
# Standard Ubuntu + PyTorch setup for comparison with muinference
#
# This represents a "normal" deployment that muinference improves upon
# by demonstrating the reduced attack surface of the Weight Enclave approach.

FROM nvidia/cuda:12.1-runtime-ubuntu22.04

LABEL maintainer="muinference"
LABEL description="Baseline GPU inference stack for security comparison"

# Prevent interactive prompts
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies
RUN apt-get update && apt-get install -y \
    python3 \
    python3-pip \
    python3-dev \
    git \
    curl \
    wget \
    vim \
    htop \
    net-tools \
    iproute2 \
    && rm -rf /var/lib/apt/lists/*

# Install Python ML dependencies
RUN pip3 install --no-cache-dir \
    torch \
    transformers \
    accelerate \
    safetensors \
    sentencepiece \
    protobuf \
    flask \
    gunicorn \
    pycryptodome

# Create app directory
WORKDIR /app

# Copy inference server
COPY server.py /app/
COPY requirements.txt /app/

# Install any additional requirements
RUN pip3 install --no-cache-dir -r /app/requirements.txt || true

# Create model directory
RUN mkdir -p /models

# Expose HTTP port
EXPOSE 8000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8000/health || exit 1

# Run the server
CMD ["python3", "/app/server.py"]

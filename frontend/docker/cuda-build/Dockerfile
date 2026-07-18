# syntax=docker/dockerfile:1
#
# Meetily CUDA Build Container
# ============================
#
# Builds the Meetily Tauri desktop binary with NVIDIA CUDA GPU acceleration
# on Linux. Produces an AppImage and/or .deb package.
#
# Usage:
#   cd /path/to/meetily
#   podman build --build-arg CUDA_ARCH=75 \
#     -t meetily-cuda-builder \
#     -f frontend/docker/cuda-build/Dockerfile .
#
#   # Extract artifacts:
#   id=$(podman create meetily-cuda-builder)
#   podman cp "$id":/bundle/. ./dist/
#   podman rm "$id"
#
# Build arguments:
#   CUDA_VERSION                 – CUDA toolkit version          (default: 12.3.1)
#   UBUNTU_VERSION               – Ubuntu base version           (default: 22.04)
#   CUDA_ARCH                    – NVIDIA compute cap × 10       (default: 75)
#   NODE_VERSION                 – Node.js major version         (default: 20)
#   TAURI_SIGNING_PRIVATE_KEY    – Tauri signing key (optional)
#   TAURI_SIGNING_PRIVATE_KEY_PASSWORD – Tauri signing key password (optional)

ARG CUDA_VERSION=12.3.1
ARG UBUNTU_VERSION=22.04

# ──────────────────────────────────────────────────────
# Stage: builder – all build dependencies + source
# ──────────────────────────────────────────────────────
FROM docker.io/nvidia/cuda:${CUDA_VERSION}-devel-ubuntu${UBUNTU_VERSION} AS builder

ARG DEBIAN_FRONTEND=noninteractive
ARG CUDA_ARCH=89
ARG NODE_VERSION=20
ARG TAURI_SIGNING_PRIVATE_KEY=""
ARG TAURI_SIGNING_PRIVATE_KEY_PASSWORD=""

# ── Install system build dependencies ─────────────────
RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    pkg-config \
    git \
    curl \
    wget \
    file \
    # Tauri 2.x Linux dependencies
    libwebkit2gtk-4.1-dev \
    libgtk-3-dev \
    libayatana-appindicator3-dev \
    librsvg2-dev \
    libssl-dev \
    libsoup-3.0-dev \
    libjavascriptcoregtk-4.1-dev \
    # Audio capture (cpal)
    libasound2-dev \
    libpulse-dev \
    # Required by bindgen (whisper-rs / llama-cpp-2 C++ bindings)
    libclang-dev \
    # linuxdeploy / AppImage in containers
    libfuse2 \
    patchelf \
    desktop-file-utils \
    # GStreamer (needed by linuxdeploy-plugin-gstreamer)
    libgstreamer1.0-0 \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly \
    libgstreamer-plugins-base1.0-dev \
    libgstreamer-plugins-bad1.0-dev \
    # RPM packaging (rpmbuild)
    rpm \
    # Misc
    libsqlite3-dev \
    libdbus-1-dev \
    && rm -rf /var/lib/apt/lists/*

# ── Install NCCL (needed by llama-cpp-2 CUDA ggml) ───
# The NVIDIA ML repository provides libnccl-dev for multi-GPU support.
# After install, symlink into CUDA's lib directory so the linker finds it.
RUN curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb \
        -o /tmp/cuda-keyring.deb && \
    dpkg -i /tmp/cuda-keyring.deb && \
    apt-get update && \
    apt-get install -y --allow-change-held-packages libnccl-dev libnccl2 && \
    rm -rf /var/lib/apt/lists/* /tmp/cuda-keyring.deb && \
    ln -sf /usr/lib/x86_64-linux-gnu/libnccl.so /usr/local/cuda/lib64/libnccl.so && \
    ln -sf /usr/lib/x86_64-linux-gnu/libnccl.so.2 /usr/local/cuda/lib64/libnccl.so.2 && \
    ln -sf /usr/include/nccl.h /usr/local/cuda/include/nccl.h

# ── Install Rust toolchain ────────────────────────────
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain stable --profile minimal

ENV PATH="/root/.cargo/bin:${PATH}"
RUN rustup component add rust-src

# ── Install Node.js and pnpm ──────────────────────────
RUN curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g pnpm

# ── Set CUDA / build environment ──────────────────────
ENV CUDA_PATH=/usr/local/cuda
ENV PATH="${CUDA_PATH}/bin:${PATH}"
ENV LD_LIBRARY_PATH="${CUDA_PATH}/lib64:${LD_LIBRARY_PATH}"
ENV CMAKE_CUDA_ARCHITECTURES="${CUDA_ARCH}"
ENV CMAKE_CUDA_STANDARD=17
ENV CMAKE_POSITION_INDEPENDENT_CODE=ON
ENV NO_STRIP=true
# linuxdeploy/AppImage: extract instead of using FUSE (not available in containers)
ENV APPIMAGE_EXTRACT_AND_RUN=1

WORKDIR /app
COPY . .

# ── Install frontend dependencies ─────────────────────
RUN cd frontend && pnpm install --no-frozen-lockfile

# ── Build Next.js frontend ────────────────────────────
RUN cd frontend && pnpm build

# ── Build llama-helper sidecar (CUDA) ─────────────────
# NCCL symbols are baked into the bundled ggml-cuda.cu even with
# GGML_CUDA_NCCL=OFF. Add -lnccl explicitly so the linker resolves them.
RUN cd llama-helper && \
    RUSTFLAGS="-L /usr/local/cuda/lib64 -l nccl" \
    cargo build --release --features cuda

# ── Copy llama-helper binary into Tauri sidecar dir ───
RUN mkdir -p /app/frontend/src-tauri/binaries && \
    TARGET_TRIPLE=$(rustc -vV | grep "host:" | awk '{print $2}') && \
    cp /app/target/release/llama-helper \
       "/app/frontend/src-tauri/binaries/llama-helper-${TARGET_TRIPLE}"

# ── Build Tauri app with CUDA ─────────────────────────
# whisper-rs with CUDA uses the same ggml code as llama-helper.
# AppImage is excluded because linuxdeploy (FUSE) doesn't work in containers.
# Signing key is optional — pass via --build-arg to enable signed updater artifacts.
# When no key is provided, the ARG defaults to empty and Tauri skips signing.
ENV TAURI_SIGNING_PRIVATE_KEY=${TAURI_SIGNING_PRIVATE_KEY}
ENV TAURI_SIGNING_PRIVATE_KEY_PASSWORD=${TAURI_SIGNING_PRIVATE_KEY_PASSWORD}
RUN cd frontend && \
    RUSTFLAGS="-L /usr/local/cuda/lib64 -l nccl" \
    npx tauri build --bundles deb --bundles rpm -- --features cuda

# ── Copy built bundles to a stable location ──────────
RUN mkdir -p /bundle && \
    cp -r /app/frontend/src-tauri/target/release/bundle/* /bundle/ 2>/dev/null; \
    ls -la /bundle/

# ──────────────────────────────────────────────────────
# Stage: export – scratch image with only the bundles
# ──────────────────────────────────────────────────────
# Use: podman build --target export ... && podman create ...
FROM scratch AS export

COPY --from=builder /bundle/ /bundle/

# ──────────────────────────────────────────────────────
# Default target: builder (inspectable, /bundle/ inside)
# ──────────────────────────────────────────────────────
# The /bundle/ directory contains the finished AppImage,
# .deb, .rpm, etc. Extract with:
#   id=$(podman create meetily-cuda-builder)
#   podman cp "$id":/bundle/. ./dist/
#   podman rm "$id"

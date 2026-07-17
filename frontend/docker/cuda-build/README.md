# 🐳 Meetily CUDA Build Container

Build the Meetily Tauri desktop binary with **NVIDIA CUDA GPU acceleration** inside a Podman container — no need to install Rust, Node.js, or CUDA toolkit on your host machine.

## 📁 Contents

| File | Description |
|---|---|
| `Dockerfile` | Multi-stage container that builds the full Tauri app with CUDA |
| `build.sh` | Convenience script — builds the image and extracts artifacts |
| `extract.sh` | Standalone script — extracts bundles from an already-built image |
| `README.md` | This file |

---

## 🚀 Quick Start

### Prerequisites

- **Podman** — [Install Podman](https://podman.io/docs/installation)
- **nvidia-container-toolkit** — [Install guide](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
  ```bash
  sudo nvidia-ctk runtime configure --runtime=podman
  sudo systemctl restart podman
  ```
- **NVIDIA GPU** with proprietary drivers on the host

### One-Command Build

```bash
# From the project root:
./frontend/docker/cuda-build/build.sh
```

This auto-detects your GPU's compute capability, builds the container, and extracts the AppImage/`.deb` into `./dist/`.

### Manual Build

```bash
# 1. Build the image
podman build \
  --build-arg CUDA_ARCH=75 \
  -t meetily-cuda-builder \
  -f frontend/docker/cuda-build/Dockerfile .

# 2. Extract artifacts
id=$(podman create meetily-cuda-builder)
mkdir -p ./dist
podman cp "$id":/bundle/. ./dist/
podman rm "$id"

# 3. Find your build
ls ./dist/
```

---

## ⚙️ Build Arguments

| Argument | Default | Description |
|---|---|---|
| `CUDA_ARCH` | `75` | NVIDIA compute capability × 10 (e.g., `75` for 7.5, `86` for 8.6, `89` for 8.9) |
| `CUDA_VERSION` | `12.3.1` | CUDA toolkit version in the base image |
| `UBUNTU_VERSION` | `22.04` | Ubuntu version for the base image |
| `NODE_VERSION` | `20` | Node.js major version |

### Compute Capability Reference

| GPU | Compute Capability | `CUDA_ARCH` value |
|---|---|---|
| GTX 1080 | 6.1 | `61` |
| RTX 2080 | 7.5 | `75` |
| RTX 3080 / A100 | 8.0 | `80` |
| RTX 3090 | 8.6 | `86` |
| RTX 4090 / H100 | 8.9 | `89` |
| RTX 5090 | 10.0 | `100` |

Find yours:

```bash
nvidia-smi --query-gpu=compute_cap --format=csv
```

---

## 📦 What Gets Built

The container performs these steps in order:

1. **System dependencies** — Tauri 2.x webkit libs, audio capture libs, CUDA toolkit, build tools
2. **Rust toolchain** — via rustup (stable, minimal profile)
3. **Node.js 20 + pnpm** — for the frontend build
4. **`pnpm install`** — installs frontend dependencies
5. **`pnpm build`** — builds the Next.js frontend into `frontend/out/`
6. **llama-helper sidecar** — `cargo build --release --features cuda`
7. **Sidecar copy** — copies the llama-helper binary into `src-tauri/binaries/`
8. **`tauri build`** — full Tauri production build with `--features cuda`

**Output formats** (inside `/bundle/` in the image):

| Format | File |
|---|---|
| Debian | `meetily_*_amd64.deb` |
| RPM | `meetily-*.x86_64.rpm` |

> **Note**: AppImage is excluded from the container build because `linuxdeploy` relies on FUSE, which is unavailable inside containers. To build an AppImage, extract the `.deb` or compile on a host with FUSE support.

---

## 📋 Script Options

```text
Usage: build.sh [OPTIONS]

  --arch NUM     NVIDIA compute capability × 10 (auto-detected if omitted)
  --no-cache     Disable Podman build cache (full rebuild)
  --tag NAME     Container image tag (default: meetily-cuda-builder:latest)
  --push         Push the built image to a registry
  --help         Show help

Examples:
  build.sh                       # Auto-detect GPU + build
  build.sh --arch 86             # Force RTX 3090 compute capability
  build.sh --no-cache            # Clean rebuild (no cache)
  build.sh --tag myrepo/builder  # Custom tag
```

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Build Context (project root)              │
│  ┌─────────────┐  ┌──────────────┐  ┌────────────────────┐  │
│  │ frontend/   │  │ llama-helper/│  │ Cargo.toml         │  │
│  │ (Next.js)   │  │ (sidecar)    │  │ (workspace root)   │  │
│  └──────┬──────┘  └──────┬───────┘  └────────────────────┘  │
└─────────┼─────────────────┼──────────────────────────────────┘
          │                 │
          ▼                 ▼
┌─────────────────────────────────────────────────────────────┐
│              nvidia/cuda:12.3.1-devel-ubuntu22.04             │
│                                                               │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │  Stage: builder                                          │ │
│  │  ┌──────────────┐  ┌──────────────┐  ┌───────────────┐  │ │
│  │  │ System deps  │→│ Rust + Node  │→│ CUDA env      │  │ │
│  │  └──────────────┘  └──────────────┘  └───────────────┘  │ │
│  │         │                                                 │ │
│  │         ▼                                                 │ │
│  │  ┌─────────────────────────────────────────────────────┐  │ │
│  │  │ 1. pnpm install                                     │  │ │
│  │  │ 2. pnpm build (Next.js → out/)                      │  │ │
│  │  │ 3. cargo build --release --features cuda (llama)     │  │ │
│  │  │ 4. Copy sidecar binary                               │  │ │
│  │  │ 5. tauri build -- --features cuda                    │  │ │
│  │  │ 6. Copy bundles → /bundle/                           │  │ │
│  │  └─────────────────────────────────────────────────────┘  │ │
│  └─────────────────────────────────────────────────────────┘ │
│                                                               │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │  Stage: export (scratch, --target export)                │ │
│  │  Only /bundle/ — for minimal artifact extraction         │ │
│  └─────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

---

## 🧹 Caching & Performance

- **Layer caching**: Podman caches each `RUN` instruction. Code changes after `COPY . .` will invalidate subsequent layers. The dependency install layers (`apt-get`, `rustup`, `npm`) are cached across builds.
- **`--no-cache`**: Use for a fully clean rebuild if you suspect stale cache issues.
- **Build time**: First build is slow (downloads deps, compiles Rust crates). Subsequent builds are faster thanks to caching.
- **`.dockerignore`**: The project root's `.dockerignore` excludes `target/`, `node_modules/`, `backend/`, and other unnecessary files from the build context.

---

## 🐳 Podman vs Docker

The Dockerfile is compatible with both Podman and Docker. The `build.sh` script is Podman-specific.

To use with Docker instead of Podman:

```bash
docker build \
  --build-arg CUDA_ARCH=75 \
  -t meetily-cuda-builder \
  -f frontend/docker/cuda-build/Dockerfile .

id=$(docker create meetily-cuda-builder)
mkdir -p ./dist
docker cp "$id":/bundle/. ./dist/
docker rm "$id"
```

> **Note**: With Docker you'll need `nvidia-container-toolkit` configured for the Docker runtime instead of Podman.

---

## ❓ Troubleshooting

### "nvidia-container-toolkit may not be configured"

The build will still succeed — it just won't have GPU acceleration available at runtime (which isn't needed for compilation anyway). The CUDA toolkit headers inside the image are sufficient for building CUDA-enabled binaries.

```bash
# Fix for Podman:
sudo nvidia-ctk runtime configure --runtime=podman
sudo systemctl restart podman
```

### Build fails with "CUDA not found"

The base image `nvidia/cuda:*-devel` includes the full CUDA toolkit. If you're seeing this, ensure you're pulling the correct image:

```bash
podman pull docker.io/nvidia/cuda:12.3.1-devel-ubuntu22.04
```

### Build fails on Rust compilation

The `--features cuda` flag requires the CUDA toolkit headers. Verify the `CUDA_PATH` environment variable is set correctly inside the container. If you're seeing `nvcc` not found, check that the `devel` (not `runtime`) variant of the CUDA image is being used.

### "undefined symbol: nccl*" during linking

The CUDA build of `llama-cpp-2`/`ggml` requires NCCL (NVIDIA Collective Communications Library) for multi-GPU support. The Dockerfile installs it from the NVIDIA ML repository via the `cuda-keyring` package.

If you see NCCL linker errors, ensure the `cuda-keyring` repository setup step ran successfully. You can also manually verify:

```bash
# Inside the container:
dpkg -l | grep nccl
```

### "Unable to find libclang" during compilation

The C/C++ bindings in `whisper-rs` and `llama-cpp-2` require `libclang-dev` at compile time. This is already included in the Dockerfile — if you're seeing this error, make sure you're using the latest version of the image (rebuild without cache):

```bash
./frontend/docker/cuda-build/build.sh --no-cache
```

### No AppImage/deb in output

Check the Tauri configuration in `frontend/src-tauri/tauri.conf.json` to ensure Linux bundles are configured:

```json
"bundle": {
  "linux": {
    "deb": { ... },
    "appimage": { ... },
    "rpm": { ... }
  }
}
```

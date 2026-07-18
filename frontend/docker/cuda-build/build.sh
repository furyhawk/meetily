#!/bin/bash
#
# Meetily CUDA Build Container – Build Script
# ============================================
#
# Builds the Meetily Tauri binary inside a Podman container
# with NVIDIA CUDA GPU acceleration.
#
# Prerequisites:
#   - Podman installed (https://podman.io)
#   - nvidia-container-toolkit installed and configured
#     (https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html)
#   - NVIDIA GPU with proper drivers on the host
#
# Usage:
#   ./frontend/docker/cuda-build/build.sh                        # Auto-detect compute capability
#   ./frontend/docker/cuda-build/build.sh --arch 86              # Force compute capability 8.6
#   ./frontend/docker/cuda-build/build.sh --signing-key "..."    # Enable signed updater artifacts
#   ./frontend/docker/cuda-build/build.sh --help                 # Show help
#
# Signing keys are automatically loaded from frontend/.env (or .env at
# project root) if present. They can also be set explicitly via CLI args
# (--signing-key, --signing-key-password) or environment variables
# (TAURI_SIGNING_PRIVATE_KEY, TAURI_SIGNING_PRIVATE_KEY_PASSWORD).
#
# Output:
#   Built bundles (AppImage, .deb, etc.) are placed in ./dist/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# ── Defaults ──────────────────────────────────────────
CUDA_ARCH=""
FORCE_REBUILD=false
NO_CACHE=""
PUSH=false
TAG="localhost/meetily-cuda-builder:latest"
TAURI_SIGNING_PRIVATE_KEY="${TAURI_SIGNING_PRIVATE_KEY:-}"
TAURI_SIGNING_PRIVATE_KEY_PASSWORD="${TAURI_SIGNING_PRIVATE_KEY_PASSWORD:-}"

# ── Colour output ─────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}ℹ${NC} $*"; }
ok()    { echo -e "${GREEN}✔${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
err()   { echo -e "${RED}✘${NC} $*" >&2; }

# ── Load .env file if present ─────────────────────────
# Looks for frontend/.env, then .env at project root.
ENV_FILE=""
for candidate in "$PROJECT_ROOT/frontend/.env" "$PROJECT_ROOT/.env"; do
    if [[ -f "$candidate" ]]; then
        ENV_FILE="$candidate"
        break
    fi
done

if [[ -n "$ENV_FILE" ]]; then
    info "Loading environment from $ENV_FILE"
    set -a
    source "$ENV_FILE"
    set +a
    # Re-read after sourcing .env so env vars take effect
    TAURI_SIGNING_PRIVATE_KEY="${TAURI_SIGNING_PRIVATE_KEY:-}"
    TAURI_SIGNING_PRIVATE_KEY_PASSWORD="${TAURI_SIGNING_PRIVATE_KEY_PASSWORD:-}"
fi

# ── Help ──────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Build Meetily using a Podman container with CUDA GPU acceleration.

Options:
  --arch NUM     NVIDIA compute capability × 10 (e.g. 75 for compute 7.5)
                 Auto-detected from nvidia-smi if omitted.
  --no-cache        Disable Podman build cache.
  --force-rebuild   Force a full rebuild even if the image already exists.
  --tag NAME        Container image tag (default: localhost/meetily-cuda-builder:latest).
  --push            Push the built image (not the app) to a registry after build.
  --signing-key KEY
                 Tauri signing private key (base64). Can also be set via
                 TAURI_SIGNING_PRIVATE_KEY environment variable.
  --signing-key-password PASSWORD
                 Tauri signing private key password. Can also be set via
                 TAURI_SIGNING_PRIVATE_KEY_PASSWORD environment variable.
  --help         Show this help.

Examples:
  $(basename "$0")
  $(basename "$0") --arch 86       # RTX 3080 = compute 8.6
  $(basename "$0") --no-cache      # Full clean rebuild

Compute capability reference:
  GPU                 Compute Capability
  GTX 1080            6.1  → 61
  RTX 2080            7.5  → 75
  RTX 3080 / A100     8.0  → 80
  RTX 3090            8.6  → 86
  RTX 4090 / H100     8.9  → 89
  RTX 5090           10.0  → 100

Prerequisites:
  - podman        (https://podman.io/docs/installation)
  - nvidia-container-toolkit
    (https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
EOF
    exit 0
}

# ── Parse args ────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)          CUDA_ARCH="$2"; shift 2 ;;
        --no-cache)      NO_CACHE="--no-cache"; shift ;;
        --force-rebuild) FORCE_REBUILD=true; shift ;;
        --tag)           TAG="$2"; shift 2 ;;
        --push)    PUSH=true; shift ;;
        --signing-key)           TAURI_SIGNING_PRIVATE_KEY="$2"; shift 2 ;;
        --signing-key-password)  TAURI_SIGNING_PRIVATE_KEY_PASSWORD="$2"; shift 2 ;;
        --help)    usage ;;
        *)         err "Unknown option: $1"; usage ;;
    esac
done

# ── Auto-detect CUDA architecture ─────────────────────
if [[ -z "$CUDA_ARCH" ]]; then
    if command -v nvidia-smi &>/dev/null; then
        COMPUTE_CAP=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 || true)
        if [[ -n "$COMPUTE_CAP" ]]; then
            # Convert "7.5" → "75", "8.6" → "86" etc.
            CUDA_ARCH=$(echo "$COMPUTE_CAP" | awk -F. '{print $1$2}')
            info "Auto-detected compute capability: $COMPUTE_CAP → arch $CUDA_ARCH"
        fi
    fi
fi

if [[ -z "$CUDA_ARCH" ]]; then
    warn "Could not auto-detect GPU compute capability, defaulting to 75 (Turing/GTX 16xx/RTX 20xx)."
    warn "Set with: $0 --arch <NUM>"
    CUDA_ARCH=75
fi

# ── Verify Podman + GPU access ────────────────────────
if ! command -v podman &>/dev/null; then
    err "Podman is not installed. Install it first: https://podman.io/docs/installation"
    exit 1
fi

info "Checking NVIDIA container toolkit..."
if ! podman info 2>/dev/null | grep -q 'nvidia'; then
    warn "nvidia-container-toolkit may not be configured for Podman."
    warn "See: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html"
    warn ""
    warn "Quick fix (as root or via sudo):"
    warn "  sudo nvidia-ctk runtime configure --runtime=podman"
    warn "  sudo systemctl restart podman"
    warn ""
    warn "Continuing anyway — GPU acceleration will NOT be available inside the container."
fi

# ── Create output directory ───────────────────────────
OUTPUT_DIR="$PROJECT_ROOT/dist"
mkdir -p "$OUTPUT_DIR"
info "Output directory: $OUTPUT_DIR"

# ── Build or reuse the container image ────────────────
IMAGE_EXISTS=false
if podman image exists "$TAG" 2>/dev/null; then
    IMAGE_EXISTS=true
fi

if [[ "$FORCE_REBUILD" == false && "$IMAGE_EXISTS" == true ]]; then
    info "Using existing image: $TAG"
    info "Run with --force-rebuild to rebuild from scratch."
else
    if [[ "$FORCE_REBUILD" == true ]]; then
        info "Force-rebuilding container image ($TAG)..."
    else
        info "Building container image ($TAG)${NO_CACHE:+, no-cache}..."
    fi

    BUILD_ARGS=(
        --build-arg "CUDA_ARCH=$CUDA_ARCH"
        -t "$TAG"
        -f "$SCRIPT_DIR/Dockerfile"
    )

    if [[ -n "$NO_CACHE" ]]; then
        BUILD_ARGS+=("$NO_CACHE")
    fi

    # Pass signing keys to the container (optional — enables signed updater artifacts)
    if [[ -n "$TAURI_SIGNING_PRIVATE_KEY" ]]; then
        BUILD_ARGS+=(--build-arg "TAURI_SIGNING_PRIVATE_KEY=$TAURI_SIGNING_PRIVATE_KEY")
    fi
    if [[ -n "$TAURI_SIGNING_PRIVATE_KEY_PASSWORD" ]]; then
        BUILD_ARGS+=(--build-arg "TAURI_SIGNING_PRIVATE_KEY_PASSWORD=$TAURI_SIGNING_PRIVATE_KEY_PASSWORD")
    fi

    # We run the build from the project root so the full source is in context
    # Use a .dockerignore to exclude unnecessary files
    BUILD_CONTEXT="$PROJECT_ROOT"

    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  podman build${NC}"
    echo -e "${BLUE}  Context:  $BUILD_CONTEXT${NC}"
    echo -e "${BLUE}  Tag:      $TAG${NC}"
    echo -e "${BLUE}  Arch:     $CUDA_ARCH${NC}"
    if [[ -n "$TAURI_SIGNING_PRIVATE_KEY" ]]; then
        echo -e "${BLUE}  Signing:  enabled${NC}"
    else
        echo -e "${YELLOW}  Signing:  disabled (no private key)${NC}"
    fi
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    podman build "${BUILD_ARGS[@]}" "$BUILD_CONTEXT"

    echo ""
    ok "Container image built: $TAG"
fi

# ── Extract built artifacts ───────────────────────────
echo ""
info "Extracting build artifacts from container..."

# Use a temporary container to copy the bundles out
CONTAINER_ID=$(podman create "$TAG" true)
trap 'podman rm -f "$CONTAINER_ID" &>/dev/null || true' EXIT

# Copy the bundle directory from the export stage
podman cp "$CONTAINER_ID":/bundle/. "$OUTPUT_DIR/" 2>/dev/null || {
    warn "No bundles found in export stage; trying to locate target/release/bundle..."
    # Fallback: try the intermediate build output
    podman cp "$CONTAINER_ID":/app/target/release/bundle/. "$OUTPUT_DIR/" 2>/dev/null || {
        warn "Could not extract bundles automatically."
        warn "They may still be inside the image. Run the container interactively:"
        warn "  podman run --rm -it $TAG /bin/bash"
    }
}

podman rm -f "$CONTAINER_ID"
trap - EXIT

echo ""
if ls "$OUTPUT_DIR"/*.AppImage "$OUTPUT_DIR"/*.deb &>/dev/null 2>&1; then
    ok "Build artifacts extracted to: $OUTPUT_DIR"
    ls -lh "$OUTPUT_DIR"/*.AppImage "$OUTPUT_DIR"/*.deb 2>/dev/null || ls -lh "$OUTPUT_DIR"/
else
    warn "Output directory: $OUTPUT_DIR"
    ls -lh "$OUTPUT_DIR"/ 2>/dev/null || true
    warn "(No AppImage/deb files found — the build may have failed or these formats weren't produced.)"
fi

# ── Push image if requested ───────────────────────────
if [[ "$PUSH" == true ]]; then
    echo ""
    info "Pushing image $TAG..."
    podman push "$TAG"
    ok "Image pushed: $TAG"
fi

echo ""
ok "Done!"

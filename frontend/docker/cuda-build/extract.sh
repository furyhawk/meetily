#!/bin/bash
#
# Meetily CUDA Build Container – Artifact Extraction Script
# =========================================================
#
# Extracts built bundles (.deb, .rpm, AppImage) from a previously
# built container image. Run this after a successful build.
#
# Usage:
#   ./frontend/docker/cuda-build/extract.sh                    # Default tag
#   ./frontend/docker/cuda-build/extract.sh --tag mytag        # Custom tag
#   ./frontend/docker/cuda-build/extract.sh --out ./artifacts  # Custom output dir
#   ./frontend/docker/cuda-build/extract.sh --help             # Show help
#
# Output:
#   Bundles are copied to ./dist/ (or --out <dir>)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# ── Defaults ──────────────────────────────────────────
TAG="meetily-cuda-builder:latest"
OUTPUT_DIR="$PROJECT_ROOT/dist"

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

# ── Help ──────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Extract built bundles from a Meetily CUDA builder container image.

Options:
  --tag NAME    Container image tag (default: meetily-cuda-builder:latest).
  --out DIR     Output directory (default: ./dist/).
  --help        Show this help.

Examples:
  $(basename "$0")
  $(basename "$0") --tag meetily-cuda-builder:latest
  $(basename "$0") --out ./artifacts
EOF
    exit 0
}

# ── Parse args ────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag) TAG="$2"; shift 2 ;;
        --out) OUTPUT_DIR="$2"; shift 2 ;;
        --help) usage ;;
        *) err "Unknown option: $1"; usage ;;
    esac
done

# ── Verify image exists ───────────────────────────────
if ! podman image exists "$TAG" 2>/dev/null; then
    err "Container image '$TAG' not found."
    err ""
    err "Build it first:"
    err "  $SCRIPT_DIR/build.sh"
    err ""
    err "Or specify a different tag:"
    err "  $(basename "$0") --tag <name>"
    exit 1
fi

# ── Create output directory ───────────────────────────
mkdir -p "$OUTPUT_DIR"

# ── Extract bundles ───────────────────────────────────
info "Extracting bundles from '$TAG'..."
info "Output: $OUTPUT_DIR"
echo ""

# Create a temporary container from the image
CONTAINER_ID=$(podman create "$TAG" true)
trap 'podman rm -f "$CONTAINER_ID" &>/dev/null || true' EXIT

# Try /bundle/ first (builder stage), fall back to target/release/bundle
if podman cp "$CONTAINER_ID":/bundle/. "$OUTPUT_DIR/" 2>/dev/null; then
    ok "Extracted from /bundle/"
else
    warn "/bundle/ not found, trying target/release/bundle..."
    if podman cp "$CONTAINER_ID":/app/frontend/src-tauri/target/release/bundle/. "$OUTPUT_DIR/" 2>/dev/null; then
        ok "Extracted from target/release/bundle/"
    else
        err "No bundles found in the image."
        err ""
        err "The build may have failed or the image doesn't contain build artifacts."
        err "Check the build logs:"
        err "  $SCRIPT_DIR/build.sh --no-cache 2>&1 | tee build.log"
        podman rm -f "$CONTAINER_ID" &>/dev/null || true
        trap - EXIT
        exit 1
    fi
fi

# Clean up
podman rm -f "$CONTAINER_ID" &>/dev/null || true
trap - EXIT

# ── Report results ────────────────────────────────────
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Extracted bundles${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

FOUND=0
for fmt in deb rpm AppImage; do
    matches=("$OUTPUT_DIR"/*."$fmt" 2>/dev/null || true)
    if [[ -f "${matches[0]}" ]]; then
        for f in "${matches[@]}"; do
            if [[ -f "$f" ]]; then
                size=$(du -h "$f" | cut -f1)
                echo -e "  ${GREEN}✔${NC} $(basename "$f")  (${size})"
                FOUND=$((FOUND + 1))
            fi
        done
    fi
done

if [[ $FOUND -eq 0 ]]; then
    warn "No .deb, .rpm, or AppImage files found in output directory."
    warn "Contents of $OUTPUT_DIR:"
    ls -lh "$OUTPUT_DIR/"
fi

echo ""
ok "Done — bundles are in: $OUTPUT_DIR"

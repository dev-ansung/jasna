#!/usr/bin/env bash
set -euo pipefail

# ── configurable ──────────────────────────────────────────────────────────────
# To update ffmpeg: swap this URL for a newer BtbN autobuild. The strip path
# "*/bin/ffmpeg" and "*/bin/ffprobe" is stable across ffmpeg 8.x releases.
FFMPEG_URL="https://github.com/BtbN/FFmpeg-Builds/releases/download/autobuild-2026-05-26-13-56/ffmpeg-n8.1.1-8-gb21e00eda5-linux64-gpl-8.1.tar.xz"
FFMPEG_DIR="$HOME/.local/jasna/ffmpeg"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HF_BASE="https://huggingface.co/ladaapp/lada/resolve/main"
DOWNLOAD_ALL_MODELS=0
# ─────────────────────────────────────────────────────────────────────────────

for arg in "$@"; do
    case $arg in
        --all-models) DOWNLOAD_ALL_MODELS=1 ;;
    esac
done

step() { echo; echo "━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }
skip() { echo "  [skip] $*"; }
info() { echo "  $*"; }

check_uv() {
    step "check: uv"
    if ! command -v uv &>/dev/null; then
        echo "ERROR: uv not found. Install it first:"
        echo "  curl -LsSf https://astral.sh/uv/install.sh | sh"
        echo "  Then reload your shell and re-run this script."
        exit 1
    fi
    info "$(uv --version)"
}

install_system_deps() {
    step "system packages (mkvtoolnix git curl)"
    if command -v mkvmerge &>/dev/null; then
        skip "mkvmerge already on PATH ($(command -v mkvmerge))"
        return
    fi
    apt-get update
    apt-get install -y mkvtoolnix git curl
}

install_ffmpeg() {
    step "ffmpeg 8"
    if [[ -x "$FFMPEG_DIR/ffmpeg" ]]; then
        skip "binary already at $FFMPEG_DIR/ffmpeg"
    else
        info "downloading $FFMPEG_URL"
        mkdir -p "$FFMPEG_DIR"
        curl -L --progress-bar "$FFMPEG_URL" \
            | tar -xJ --strip-components=2 -C "$FFMPEG_DIR" \
                  --wildcards "*/bin/ffmpeg" "*/bin/ffprobe"
        chmod +x "$FFMPEG_DIR/ffmpeg" "$FFMPEG_DIR/ffprobe"
        info "extracted: $FFMPEG_DIR/ffmpeg $FFMPEG_DIR/ffprobe"
    fi

    info "symlinking into /usr/bin ..."
    ln -sfv "$FFMPEG_DIR/ffmpeg"  /usr/bin/ffmpeg
    ln -sfv "$FFMPEG_DIR/ffprobe" /usr/bin/ffprobe
    info "$(ffmpeg -version 2>&1 | head -1)"
}

install_gpu_libs() {
    step "CUDA check"
    if ! command -v nvcc &>/dev/null; then
        echo "ERROR: nvcc not found. Install CUDA 13 toolkit first:"
        echo "  https://developer.nvidia.com/cuda-downloads"
        exit 1
    fi
    local cuda_ver
    cuda_ver=$(nvcc --version | grep -oP 'release \K[0-9]+' | head -1)
    if [[ "$cuda_ver" -lt 13 ]]; then
        echo "ERROR: CUDA $cuda_ver found, need 13."
        exit 1
    fi
    info "nvcc reports CUDA $cuda_ver"

    step "python-vali (GPU decoder)"
    if uv pip show python-vali &>/dev/null; then
        skip "$(uv pip show python-vali | grep ^Name) $(uv pip show python-vali | grep ^Version)"
    else
        uv pip install python-vali
    fi

    step "PyNvVideoCodec (GPU encoder)"
    if uv pip show PyNvVideoCodec &>/dev/null; then
        skip "$(uv pip show PyNvVideoCodec | grep ^Name) $(uv pip show PyNvVideoCodec | grep ^Version)"
    else
        uv pip install PyNvVideoCodec
    fi
}

download_models() {
    local dest="$REPO_ROOT/model_weights"
    mkdir -p "$dest"
    step "model weights -> $dest"

    local required=(
        "lada_mosaic_restoration_model_generic_v1.2.pth"
        "rfdetr-v5.onnx"
    )
    for f in "${required[@]}"; do
        if [[ -f "$dest/$f" ]]; then
            skip "$f"
        else
            info "downloading $f ..."
            curl -L --progress-bar -o "$dest/$f" "$HF_BASE/$f"
        fi
    done

    if [[ "$DOWNLOAD_ALL_MODELS" == "1" ]]; then
        local optional=(
            "rfdetr-v4.onnx"
            "rfdetr-v3.onnx"
            "rfdetr-v2.onnx"
            "lada_mosaic_detection_model_v2.pt"
            "lada_mosaic_detection_model_v4_fast.pt"
            "unet-4x.onnx"
        )
        for f in "${optional[@]}"; do
            if [[ -f "$dest/$f" ]]; then
                skip "$f"
            else
                info "downloading $f ..."
                curl -L --progress-bar -o "$dest/$f" "$HF_BASE/$f"
            fi
        done
    fi
}

install_jasna() {
    step "jasna"
    if uv pip show jasna &>/dev/null; then
        skip "$(uv pip show jasna | grep ^Version)"
        return
    fi
    cd "$REPO_ROOT"
    info "installing wheel_stub (tensorrt build backend) ..."
    uv pip install wheel_stub
    info "installing jasna and dependencies ..."
    uv pip install -e . --no-build-isolation \
        --extra-index-url https://download.pytorch.org/whl/cu130 \
        --index-strategy unsafe-best-match \
        --prerelease=allow
}

main() {
    echo "╔══════════════════════════════════════╗"
    echo "║      Jasna Linux installer           ║"
    echo "╚══════════════════════════════════════╝"
    echo "  repo:    $REPO_ROOT"
    echo "  ffmpeg:  $FFMPEG_DIR"
    check_uv
    install_system_deps
    install_ffmpeg
    install_gpu_libs
    download_models
    install_jasna
    echo
    echo "━━━ done ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Run jasna from the repo root:"
    echo "    cd $REPO_ROOT && jasna"
    echo
    echo "  If jasna is not on PATH: source ~/.bashrc"
}

main "$@"

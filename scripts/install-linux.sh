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

check_uv() {
    if ! command -v uv &>/dev/null; then
        echo "ERROR: uv not found. Install it first:"
        echo "  curl -LsSf https://astral.sh/uv/install.sh | sh"
        echo "  Then reload your shell and re-run this script."
        exit 1
    fi
    echo "==> uv $(uv --version)"
}

install_system_deps() {
    if done_stamp system_deps; then
        echo "==> [skip] system packages already installed"
        return
    fi
    echo "==> Installing system packages (mkvtoolnix, git, curl)..."
    apt-get update -qq
    apt-get install -y mkvtoolnix git curl
    mark_done system_deps
}

install_ffmpeg() {
    export PATH="$FFMPEG_DIR:$PATH"
    if [[ -x "$FFMPEG_DIR/ffmpeg" ]]; then
        echo "==> [skip] ffmpeg already installed ($(ffmpeg -version 2>&1 | head -1))"
        return
    fi
    echo "==> Installing ffmpeg 8..."
    mkdir -p "$FFMPEG_DIR"
    curl -L --progress-bar "$FFMPEG_URL" \
        | tar -xJ --strip-components=2 -C "$FFMPEG_DIR" \
              --wildcards "*/bin/ffmpeg" "*/bin/ffprobe"
    chmod +x "$FFMPEG_DIR/ffmpeg" "$FFMPEG_DIR/ffprobe"

    local shell_rc="$HOME/.bashrc"
    [[ "$SHELL" == */zsh ]] && shell_rc="$HOME/.zshrc"
    grep -qxF "export PATH=\"$FFMPEG_DIR:\$PATH\"" "$shell_rc" \
        || echo "export PATH=\"$FFMPEG_DIR:\$PATH\"" >> "$shell_rc"

    echo "    $("$FFMPEG_DIR/ffmpeg" -version 2>&1 | head -1)"
}

install_gpu_libs() {
    echo "==> Checking CUDA 13 toolkit..."
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
    echo "    CUDA $cuda_ver ok"

    if uv pip show python-vali &>/dev/null; then
        echo "==> [skip] python_vali already installed"
    else
        echo "==> Installing python_vali (GPU decoder)..."
        uv pip install python-vali
    fi

    if uv pip show PyNvVideoCodec &>/dev/null; then
        echo "==> [skip] PyNvVideoCodec already installed"
    else
        echo "==> Installing PyNvVideoCodec (GPU encoder)..."
        uv pip install PyNvVideoCodec
    fi
}

download_models() {
    local dest="$REPO_ROOT/model_weights"
    mkdir -p "$dest"
    echo "==> Downloading required model weights to $dest ..."

    local required=(
        "lada_mosaic_restoration_model_generic_v1.2.pth"
        "rfdetr-v5.onnx"
    )
    for f in "${required[@]}"; do
        if [[ -f "$dest/$f" ]]; then
            echo "    [skip] $f already present"
        else
            echo "    [download] $f"
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
                echo "    [skip] $f already present"
            else
                echo "    [download] $f"
                curl -L --progress-bar -o "$dest/$f" "$HF_BASE/$f"
            fi
        done
    fi

    echo "    Model weights ready."
}

install_jasna() {
    if uv pip show jasna &>/dev/null; then
        echo "==> [skip] jasna already installed"
        return
    fi
    echo "==> Installing jasna..."
    cd "$REPO_ROOT"
    uv pip install -e . --no-build-isolation
}

main() {
    echo "Jasna Linux installer"
    echo ""
    check_uv
    install_system_deps
    install_ffmpeg
    install_gpu_libs
    download_models
    install_jasna
    echo ""
    echo "Done. Run jasna from the repo root:"
    echo "  cd $REPO_ROOT && jasna"
    echo ""
    echo "If jasna or ffmpeg is not found, reload your shell:"
    echo "  source ~/.bashrc"
}

main "$@"

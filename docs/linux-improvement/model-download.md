# Model Download Streamlining Plan

**Goal:** Add model download to `scripts/install-linux.sh` so the user's `model_weights/` directory is populated automatically after cloning.

---

## What files are needed and where the code expects them

All model files are resolved relative to the **current working directory** when jasna is invoked. The expected layout is:

```
model_weights/
├── lada_mosaic_restoration_model_generic_v1.2.pth   ← BasicVSR++ restoration (required)
├── rfdetr-v5.onnx                                    ← default detection model (required)
├── rfdetr-v4.onnx                                    ← optional older detection model
├── rfdetr-v3.onnx                                    ← optional older detection model
├── rfdetr-v2.onnx                                    ← optional older detection model
├── lada_mosaic_detection_model_v2.pt                 ← optional YOLO detection (2D animations)
├── lada_mosaic_detection_model_v4_fast.pt            ← optional YOLO detection (2D animations)
└── unet-4x.onnx                                      ← optional secondary restoration (UNet 4x)
```

**Sources in code:**
- Restoration path hardcoded: [jasna/gui/processor.py:239](../../jasna/gui/processor.py#L239), [jasna/gui/engine_preflight.py:76](../../jasna/gui/engine_preflight.py#L76), [jasna/main.py:61](../../jasna/main.py#L61)
- Detection paths built from name: [jasna/mosaic/detection_registry.py:50-56](../../jasna/mosaic/detection_registry.py#L50-L56)
- UNet path: [jasna/engine_paths.py:43](../../jasna/engine_paths.py#L43)

**Minimum required for first run** (default settings, no optional features):
1. `lada_mosaic_restoration_model_generic_v1.2.pth`
2. `rfdetr-v5.onnx`

Everything else is optional and can be skipped unless the user explicitly selects those models.

---

## Where the files live on HuggingFace

HuggingFace repo: `https://huggingface.co/ladaapp/lada/tree/main`

Direct download base URL pattern:
```
https://huggingface.co/ladaapp/lada/resolve/main/<filename>
```

| File | HF filename | Required? |
|---|---|---|
| `lada_mosaic_restoration_model_generic_v1.2.pth` | `lada_mosaic_restoration_model_generic_v1.2.pth` | **Yes** |
| `rfdetr-v5.onnx` | `rfdetr-v5.onnx` | **Yes** (default detection) |
| `rfdetr-v4.onnx` | `rfdetr-v4.onnx` | No |
| `rfdetr-v3.onnx` | `rfdetr-v3.onnx` | No |
| `rfdetr-v2.onnx` | `rfdetr-v2.onnx` | No |
| `lada_mosaic_detection_model_v2.pt` | `lada_mosaic_detection_model_v2.pt` | No |
| `lada_mosaic_detection_model_v4_fast.pt` | `lada_mosaic_detection_model_v4_fast.pt` | No |
| `unet-4x.onnx` | `unet-4x.onnx` | No (UNet 4x secondary) |

The HF repo does not require authentication for public files — plain `curl`/`wget` works.

---

## Download approaches

### Option A — curl with progress (recommended)

No Python dependency at download time. Works on any Linux box with `curl`.

```bash
HF_BASE="https://huggingface.co/ladaapp/lada/resolve/main"

download_models() {
    local dest="$REPO_ROOT/model_weights"
    mkdir -p "$dest"
    echo "==> Downloading required model weights to $dest ..."

    # Required files — always download
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

    # Optional files — only download if user passes --all-models flag
    if [[ "${DOWNLOAD_ALL_MODELS:-0}" == "1" ]]; then
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
```

Invocation in `main()`:
```bash
main() {
    ...
    download_models
    install_jasna
    ...
}
```

Pass `--all-models` to also pull optional weights:
```bash
DOWNLOAD_ALL_MODELS=1 bash scripts/install-linux.sh
# or:
bash scripts/install-linux.sh --all-models
```

### Option B — huggingface_hub Python library

More resilient (resume, checksum, caching) but adds a Python dependency that must be resolved before the main `uv install`.

```bash
download_models_hf() {
    uv pip install huggingface_hub --quiet
    python - <<'PYEOF'
from huggingface_hub import hf_hub_download
import pathlib, os

dest = pathlib.Path(os.environ["REPO_ROOT"]) / "model_weights"
dest.mkdir(exist_ok=True)

required = [
    "lada_mosaic_restoration_model_generic_v1.2.pth",
    "rfdetr-v5.onnx",
]
for f in required:
    if (dest / f).exists():
        print(f"  [skip] {f}")
        continue
    hf_hub_download(repo_id="ladaapp/lada", filename=f, local_dir=str(dest))
    print(f"  [ok] {f}")
PYEOF
}
```

**Recommendation:** Use Option A (curl). It has zero extra dependencies, is transparent, and the files are large binaries where resume-on-failure is rarely needed for a first-run setup script. Option B is worth switching to if the HF repo ever adds authentication or if resumability becomes important.

---

## Integration into install-linux.sh

The full revised `install-linux.sh` structure with model download added:

```bash
#!/usr/bin/env bash
set -euo pipefail

FFMPEG_URL="https://github.com/BtbN/FFmpeg-Builds/releases/download/autobuild-2026-05-26-13-56/ffmpeg-n8.1.1-8-gb21e00eda5-linux64-gpl-8.1.tar.xz"
FFMPEG_DIR="$HOME/.local/jasna/ffmpeg"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HF_BASE="https://huggingface.co/ladaapp/lada/resolve/main"
DOWNLOAD_ALL_MODELS=0

# Parse flags
for arg in "$@"; do
    case $arg in
        --all-models) DOWNLOAD_ALL_MODELS=1 ;;
    esac
done

check_uv()            { ... }
install_system_deps() { ... }   # mkvtoolnix, git, curl
install_ffmpeg()      { ... }   # BtbN static build
install_gpu_libs()    { ... }   # cmake/ninja + vali + PyNvVideoCodec
download_models()     { ... }   # HF curl downloads (see above)
install_jasna()       { ... }   # uv pip install -e .

main() {
    echo "Jasna Linux installer"
    check_uv
    install_system_deps
    install_ffmpeg
    install_gpu_libs
    download_models
    install_jasna
    echo ""
    echo "Done. Run jasna from: $REPO_ROOT"
    echo "  cd $REPO_ROOT && jasna"
    echo ""
    echo "If jasna is not on PATH, reload your shell: source ~/.bashrc"
}

main "$@"
```

---

## Running directory note

The code resolves `model_weights/` **relative to the current working directory** at runtime, not relative to the script or the installed package. This means the user must `cd` into the repo root before running jasna:

```bash
cd ~/jasna
jasna --input video.mp4 --output out.mp4
```

This is a pre-existing limitation of the codebase. The install plan does not change it, but the post-install message in the script should make this explicit.

---

## File change summary

Adds to the existing plan ([plan.md](./plan.md)):

| File | Change |
|---|---|
| `scripts/install-linux.sh` | Add `download_models()` function and call in `main()` |

No Python source changes are required for model download — the existing path resolution in `detection_registry.py`, `engine_preflight.py`, and `main.py` already expects `model_weights/` in the working directory.

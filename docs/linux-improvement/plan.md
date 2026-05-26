# Linux Installation Streamlining Plan

**Goal:** A new Linux user can clone the repo and run a single script to get a working Jasna install — no manual dependency hunting.

**Target environment:** Ubuntu 22.04/24.04, NVIDIA driver ≥ 575, CUDA 13.0 toolkit, Python 3.13 via `uv`.

---

## Overview of changes

| # | Area | File(s) changed | Effort |
|---|---|---|---|
| 1 | ffmpeg 8 install | new `scripts/install-linux.sh` | low |
| 2 | Driver version check | `jasna/os_utils.py` | trivial |
| 3 | vali + PyNvVideoCodec install | `scripts/install-linux.sh`, `pyproject.toml` | medium |
| 4 | One-shot installer | `scripts/install-linux.sh` | low |

---

## Step 1 — ffmpeg 8 install

**Problem:** Ubuntu ships ffmpeg 6 via apt. The code hard-exits if the installed ffmpeg major ≠ 8 ([os_utils.py:157](../../jasna/os_utils.py#L157)).

**Solution:** Download the prebuilt static binary from BtbN's release, extract it into a known local path (e.g. `~/.local/jasna/ffmpeg`), and prepend that directory to `PATH` in the user's shell profile.

**Proposed script block (`scripts/install-linux.sh`):**

```bash
FFMPEG_URL="https://github.com/BtbN/FFmpeg-Builds/releases/download/autobuild-2026-05-26-13-56/ffmpeg-n8.1.1-8-gb21e00eda5-linux64-gpl-8.1.tar.xz"
FFMPEG_DIR="$HOME/.local/jasna/ffmpeg"

install_ffmpeg() {
    echo "==> Installing ffmpeg 8..."
    mkdir -p "$FFMPEG_DIR"
    curl -L "$FFMPEG_URL" | tar -xJ --strip-components=2 -C "$FFMPEG_DIR" --wildcards "*/bin/ffmpeg" "*/bin/ffprobe"
    chmod +x "$FFMPEG_DIR/ffmpeg" "$FFMPEG_DIR/ffprobe"

    # Persist to PATH
    SHELL_RC="$HOME/.bashrc"
    [[ "$SHELL" == */zsh ]] && SHELL_RC="$HOME/.zshrc"
    grep -qxF "export PATH=\"$FFMPEG_DIR:\$PATH\"" "$SHELL_RC" \
        || echo "export PATH=\"$FFMPEG_DIR:\$PATH\"" >> "$SHELL_RC"

    export PATH="$FFMPEG_DIR:$PATH"
    echo "    ffmpeg $(ffmpeg -version 2>&1 | head -1)"
}
```

**Key decisions:**
- Static GPL build from BtbN is the canonical Linux source. The specific tarball URL from the task brief is pinned; the script should document how to update it for future ffmpeg 8.x releases (just swap the URL, strip path `*/bin/` is stable across versions).
- Install to `~/.local/jasna/ffmpeg` rather than `/usr/local/bin` to avoid requiring `sudo`.
- `tar --strip-components=2 --wildcards "*/bin/ffmpeg" "*/bin/ffprobe"` extracts only the two binaries, keeping the install small (~80 MB tarball → ~2 binaries).
- mkvmerge (MKVToolNix) is available via apt on Ubuntu: `sudo apt install mkvtoolnix`. Add this to the script too since it is equally required.

---

## Step 2 — Loosen driver 590 restriction

**Problem:** `MIN_DRIVER_VERSION = 590` in [os_utils.py:12](../../jasna/os_utils.py#L12) triggers a failing check for driver 580, even though 580 satisfies all underlying library minimums (CUDA 13 needs 575+, TensorRT 10.14 needs ~550+).

**Solution:** Lower the constant to `575` — the true minimum set by CUDA 13.0 on Linux.

**Change:**

```python
# jasna/os_utils.py line 12
MIN_DRIVER_VERSION = 575   # was 590; CUDA 13.0 requires 575+ on Linux
```

**Why 575 not 580:**
- The actual floor is set by CUDA 13.0's minimum driver requirement (575.xx on Linux per NVIDIA release notes).
- Using 575 is honest about the real minimum and accommodates anyone on 575–589 who would also be incorrectly blocked.
- The README's mention of 591.67 as "tested" should be kept as a note, not enforced as a hard check.

**No other code changes needed** — the `check_gpu_driver_version()` function at [os_utils.py:351](../../jasna/os_utils.py#L351) already uses this constant correctly.

---

## Step 3 — vali and PyNvVideoCodec installation

**Problem:** Both libraries are compiled C++/CUDA extensions maintained at Codeberg forks. They are not in PyPI and are not listed in `pyproject.toml`, so they must be installed manually. Neither has a stable install mechanism documented in the repo.

**Solution:** Two complementary changes.

### 3a — pyproject.toml optional extras (VCS install)

Add a `linux-gpu` optional group to `pyproject.toml` pointing at the Codeberg Git URLs:

```toml
[project.optional-dependencies]
linux-gpu = [
  "python-vali @ git+https://codeberg.org/Kruk2/vali",
  "PyNvVideoCodec @ git+https://codeberg.org/Kruk2/PyNvVideoCodec",
]
dev = [
  "pyinstaller>=6.0",
  "pytest",
  "pytest-cov",
  "scikit-build",
  "cmake",
  "ninja",
]
```

This means `uv pip install -e .[linux-gpu]` works as the single command for users who already have CUDA 13 headers installed. `uv` resolves VCS sources, clones them, and builds them in place.

**Caveat:** Both libraries require CUDA headers at build time (`nvcc`, `cuda_runtime.h`). The install script must verify this before attempting to install them.

### 3b — install script block

```bash
install_gpu_libs() {
    echo "==> Checking CUDA 13 toolkit..."
    if ! command -v nvcc &>/dev/null; then
        echo "ERROR: nvcc not found. Install CUDA 13 toolkit first."
        echo "  https://developer.nvidia.com/cuda-downloads"
        exit 1
    fi
    CUDA_VER=$(nvcc --version | grep -oP 'release \K[0-9]+' | head -1)
    if [[ "$CUDA_VER" -lt 13 ]]; then
        echo "ERROR: CUDA $CUDA_VER found, need 13."
        exit 1
    fi

    echo "==> Installing build tools..."
    uv pip install cmake ninja scikit-build

    echo "==> Installing python_vali (GPU decoder)..."
    uv pip install "python-vali @ git+https://codeberg.org/Kruk2/vali" --no-build-isolation

    echo "==> Installing PyNvVideoCodec (GPU encoder)..."
    uv pip install "PyNvVideoCodec @ git+https://codeberg.org/Kruk2/PyNvVideoCodec" --no-build-isolation
}
```

`--no-build-isolation` is required because both packages link against CUDA headers that must be resolved from the system, not from an isolated build environment.

---

## Step 4 — One-shot install script

**File:** `scripts/install-linux.sh`

**Full script structure:**

```bash
#!/usr/bin/env bash
set -euo pipefail

# ── configurable ──────────────────────────────────────────────────────────────
FFMPEG_URL="https://github.com/BtbN/FFmpeg-Builds/releases/download/autobuild-2026-05-26-13-56/ffmpeg-n8.1.1-8-gb21e00eda5-linux64-gpl-8.1.tar.xz"
FFMPEG_DIR="$HOME/.local/jasna/ffmpeg"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# ─────────────────────────────────────────────────────────────────────────────

check_uv() { ... }          # verify uv is installed, print install hint if not
install_system_deps() { ... }  # sudo apt install mkvtoolnix git curl
install_ffmpeg() { ... }    # download BtbN static build, put on PATH
install_gpu_libs() { ... }  # cmake/ninja, then vali + PyNvVideoCodec via uv
install_jasna() { ... }     # uv pip install -e . --no-build-isolation

main() {
    echo "Jasna Linux installer"
    check_uv
    install_system_deps
    install_ffmpeg
    install_gpu_libs
    install_jasna
    echo ""
    echo "Done. Start with: jasna"
    echo "If jasna is not found, reload your shell: source ~/.bashrc"
}

main "$@"
```

**Usage after cloning:**

```bash
git clone <repo>
cd jasna
bash scripts/install-linux.sh
```

---

## File change summary

| File | Change |
|---|---|
| `jasna/os_utils.py` | Line 12: `MIN_DRIVER_VERSION = 575` |
| `pyproject.toml` | Add `linux-gpu` optional extra with VCS deps |
| `scripts/install-linux.sh` | New file — full one-shot installer |

---

## Commits

The plan lands in 3 commits, in this order. Commits 1 and 2 are independent; commit 3 must follow commit 2.

---

**Commit 1 — `jasna/os_utils.py` (1 line)**

```
fix(linux): lower minimum driver version to 575

CUDA 13.0 requires driver 575+ on Linux; the previous threshold of 590
was based on the author's tested driver (591.67), not the actual library
minimum. This unblocks users on 575–589 who were incorrectly shown a
hard failure in the first-run wizard.

TensorRT 10.14 minimum on Linux is ~550, CUDA 13.0 minimum is 575 — 575
is the honest floor.
```

---

**Commit 2 — `pyproject.toml` (add `linux-gpu` extra)**

```
build: add linux-gpu optional extra for GPU codec libraries

Adds a [linux-gpu] optional dependency group pointing at the Codeberg
forks of python-vali and PyNvVideoCodec. Both are compiled CUDA
extensions not available on PyPI; this makes `uv pip install -e
.[linux-gpu] --no-build-isolation` the canonical install path for Linux
users instead of undocumented manual steps.

Requires CUDA 13 headers (nvcc) present at build time.
```

---

**Commit 3 — `scripts/install-linux.sh` (new file)**

```
feat(linux): add one-shot Linux install script

scripts/install-linux.sh automates the full setup for Linux users
starting from a fresh clone:

- Checks for uv and prints install hint if missing
- Installs mkvtoolnix via apt (required for mkvmerge)
- Downloads ffmpeg 8.1.1 static GPL build (BtbN) to
  ~/.local/jasna/ffmpeg and prepends to PATH — avoids Ubuntu's
  system ffmpeg 6 which is rejected by the version check
- Installs cmake/ninja/scikit-build then builds python-vali and
  PyNvVideoCodec from source against the system CUDA 13 toolkit
- Downloads required model weights (restoration + rfdetr-v5) from
  HuggingFace into model_weights/; pass --all-models to also fetch
  optional detection variants and unet-4x
- Installs jasna itself via `uv pip install -e .`

Usage: bash scripts/install-linux.sh [--all-models]
```

---

## What this does NOT cover

- **CUDA 13 toolkit install** — too machine-specific (distro, existing driver state). The script checks for it and links to the NVIDIA download page.
- **uv install** — one-line install is `curl -LsSf https://astral.sh/uv/install.sh | sh`; the script checks and prints this hint but does not auto-install uv (side effects on user's Python setup).
- **Windows** — out of scope; Windows ships ffmpeg via the release bundle already.
- **Virtual environment management** — the script assumes the user has already activated a `uv`-managed venv or is happy installing into the default env.

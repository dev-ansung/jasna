# Jasna vs Lada: Installation & Architecture Comparison

**Question:** Why is lada easier to install, and what can jasna learn from it?

---

## Installation comparison

| | Lada | Jasna |
|---|---|---|
| **Linux (easiest path)** | `flatpak install` | clone → uv venv → bash script → 15–60 min TRT compile |
| **Windows** | extract .7z | extract .zip (ffmpeg bundled) ✓ |
| **Docker** | Yes | No |
| **GPU requirement** | NVIDIA, Intel Arc, or CPU | NVIDIA only (compute ≥7.5, CUDA 13) |
| **First-run cost** | Zero (plain PyTorch) | 15–60 min TensorRT compilation |
| **Python version** | ≥3.12 | ≥3.13 |
| **pip installable** | Yes (`pip install lada`) | No |

**The core difference:** lada ships pre-built distribution artifacts (Flatpak, Docker image, .7z). A user never touches a terminal on Linux unless they want to. Jasna has no equivalent — the only Linux path goes through the install script.

---

## Why lada is genuinely easier

### 1. No compiled engines at install time

Lada runs plain PyTorch. No TensorRT, no torch_tensorrt, no sub-engine compilation. The model just loads and runs.

Jasna's 15–60 minute first-run compilation is the single biggest usability problem. It happens silently on first run, blocks all output, and can fail with an OOM crash if the pod doesn't have enough VRAM. Users have no idea if it's working or hung.

### 2. Simpler dependency graph

**Lada's pyproject.toml dependencies:**
```
torch, torchvision, av, numpy, opencv-python,
ultralytics, mmengine, tqdm, pillow, psutil,
pygobject (GUI only), pyqt6 (GUI only)
```
All on PyPI. `pip install lada` works.

**Jasna's dependencies:**
```
torch==2.10.0+cu130          ← pytorch index only
torchvision==0.25.0+cu130    ← pytorch index only
tensorrt==10.14.1.48.post1   ← sdist-only, needs wheel_stub workaround
torch-tensorrt==2.10.0       ← version string ambiguous across indexes
python-vali                  ← PyPI but no cp313 wheel for all versions
PyNvVideoCodec               ← PyPI but no cp313 wheel for all versions
nvidia-vfx                   ← Windows-only, in main deps
customtkinter, tkinterdnd2   ← GUI-only, in main deps
```
Four separate package indexes, sdist build workarounds, version pin ambiguities. See [dependency-fragility.md](./dependency-fragility.md) for the full breakdown.

### 3. CPU and Intel fallback

Lada works on CPU (slow) and Intel Arc GPUs. This means a user can test their install without a CUDA-capable GPU. Jasna hard-fails at startup if no NVIDIA GPU is present.

### 4. `pip install lada` just works

The lada package is on PyPI, properly declared, and installs in one command on Python 3.12+. No extra indexes, no build isolation flags, no pre-installed stubs.

---

## Where jasna is better

### 1. Performance (2–3× faster)

Jasna's TensorRT compilation, hardware video decoding via python-vali, and hardware encoding via PyNvVideoCodec deliver 2–3× throughput over lada on the same GPU. On a RunPod A100 or RTX 4090 this matters — it cuts a 3-hour job to 70 minutes.

### 2. Temporal blending / flicker reduction

Lada has no temporal overlap between clips. Jasna's overlap+discard clip splitting with crossfade blending significantly reduces flickering at restoration boundaries. This is a real quality difference.

### 3. Streaming

Jasna has an HLS streaming mode and Stash integration. Lada does not.

---

## What jasna should adopt from lada

### Short term (low effort, high impact)

**1. Make `pip install jasna[linux-gpu]` work without workarounds**

The four-index, sdist-with-wheel_stub, prerelease-flag install is the primary friction point. Fixes are documented in [dependency-fragility.md](./dependency-fragility.md):
- Pin `torch-tensorrt==2.10.0+cu130` (removes index ambiguity)
- Add `https://pypi.nvidia.com` as extra index (resolves tensorrt to a wheel, no sdist build)
- Move `nvidia-vfx`, `customtkinter`, `tkinterdnd2` to optional extras

**2. Ship a Docker image**

A pre-built Docker image with CUDA 13, all dependencies installed, and model weights baked in would match lada's Flatpak story for RunPod. RunPod supports custom Docker images natively — a user would just paste the image URL and click start. Zero install script needed.

```dockerfile
FROM nvidia/cuda:13.0.0-cudnn-devel-ubuntu22.04
# pip install, download weights, done
```

**3. Provide a progress indicator for TRT compilation**

The 15–60 minute compile is unavoidable, but hiding it is not. Print elapsed time and expected duration. Consider a `--no-compile` flag that skips TRT and uses PyTorch (lada-comparable performance) for users who just want to test.

### Medium term

**4. Lower the Python requirement to 3.12**

Python 3.13 has no runtime benefit here and cuts off a large fraction of RunPod images. `python-vali` 4.8.7 ships cp311–cp314 wheels; `PyNvVideoCodec` 2.0.x ships cp310–cp312 only — this is the actual floor. Fixing the cp313 constraint may require pinning to a version of `PyNvVideoCodec` that ships a cp313 wheel or requesting one from upstream.

**5. Drop the mmagic training copy**

Both lada and jasna use `mmengine` for model loading. Lada doesn't copy mmengic into its repo — it lists `mmengine` as a pip dependency. Jasna ships 7,500 lines of MMagic training infrastructure it never uses. Deleting `jasna/models/basicvsrpp/mmagic/` and keeping `mmengine` as a dep matches lada's approach. See [rewrite-estimate.md](./rewrite-estimate.md).

---

## Summary

Lada is easier to install because it:
1. Has pre-built distribution artifacts (Flatpak, Docker, .7z) — no terminal required on Linux
2. Has a simple pip-installable package with no special indexes or build flags
3. Has no first-run compilation step

Jasna is faster and has better output quality because it uses TensorRT and hardware codecs. The install friction is not inherent to those capabilities — it is accidental complexity from the dependency graph and the absence of a Docker image. Both are fixable.

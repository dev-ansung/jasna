# Dependency Fragility Analysis

**Why the install is prone to build errors, and what to do about it.**

---

## Root causes

### 1. `tensorrt==10.14.1.48.post1` is an sdist-only package

`tensorrt` on PyPI is a meta-package that pulls in `tensorrt-cu13`, which pulls in `tensorrt-cu13-libs`. That last package **ships only as a source distribution** (no wheel). Its build backend is `wheel_stub`, but `wheel_stub` is not declared as a build dependency — so any fresh install will fail unless `wheel_stub` is pre-installed manually.

This is a packaging bug in the NVIDIA-published `tensorrt-cu13-libs` package. The workaround (`uv pip install wheel_stub` before the main install) is fragile: it relies on undocumented build-time state, breaks on a clean venv if the order changes, and could break again if NVIDIA publishes a new version with a different backend.

**Fix:** Pin the install to pre-built wheels from the NVIDIA index or the PyTorch index rather than resolving through PyPI's meta-packages. NVIDIA publishes pre-built TensorRT wheels at:
```
https://pypi.nvidia.com
```
Adding `--extra-index-url https://pypi.nvidia.com` alongside the PyTorch index should resolve `tensorrt-cu13-libs` to a wheel, eliminating the sdist build entirely.

---

### 2. `torch-tensorrt==2.10.0` version string mismatch between PyPI and the PyTorch index

`pyproject.toml` declares `torch-tensorrt==2.10.0` (bare version). On PyPI the package is named `torch-tensorrt==2.10.0` (no `+cu130` suffix). On `download.pytorch.org/whl/cu130` it is `torch-tensorrt==2.10.0+cu130`. These are treated as different versions by pip/uv.

Without `--index-strategy unsafe-best-match`, uv stops at the first index that has *any* version of `torch-tensorrt` and never sees the `+cu130` build. This is why `--index-strategy unsafe-best-match` is required, but it also means the resolver picks whichever version sorts highest across all indexes, which can be unpredictable.

**Fix:** Pin the local version explicitly in `pyproject.toml`:
```toml
"torch-tensorrt==2.10.0+cu130",
```
This removes the ambiguity entirely and makes `--index-strategy unsafe-best-match` unnecessary.

---

### 3. `nvidia-vfx` / `nvvfx` is a Windows-only dependency in the main `dependencies` list

`nvidia-vfx` is the RTX Super Resolution SDK. Its Python bindings (`nvvfx`) only exist on Windows — there is no Linux wheel. It is listed as a hard dependency in `[project.dependencies]`, so every Linux install must resolve it.

Looking at the code, `nvvfx` is only ever imported inside `rtx_superres_secondary_restorer.py` behind lazy `from nvvfx import ...` calls, and the caller guards it with a platform/availability check. The package itself is not needed at runtime on Linux.

**Fix:** Move `nvidia-vfx` out of `[project.dependencies]` and into a `windows` optional group:
```toml
[project.optional-dependencies]
windows = [
  "nvidia-vfx",
]
```
On Linux, the install simply omits it. The lazy import in `rtx_superres_secondary_restorer.py` already handles the missing module gracefully.

---

### 4. GUI dependencies (`customtkinter`, `tkinterdnd2`) pulled in on headless Linux

Both packages are only needed for the GUI code path (`jasna/gui/`). On a headless RunPod instance, Tk is not available and these packages serve no purpose. They are in `[project.dependencies]` so they install unconditionally.

This does not cause a hard build error today, but it adds unnecessary install overhead and is a potential future breakage point if either package drops Linux/headless support.

**Fix:** Move them to a `gui` optional group:
```toml
[project.optional-dependencies]
gui = [
  "customtkinter",
  "tkinterdnd2",
]
```

---

## Summary of proposed `pyproject.toml` changes

| Problem | Current | Proposed |
|---|---|---|
| tensorrt sdist build | `tensorrt==10.14.1.48.post1` (pulls sdist) | add `https://pypi.nvidia.com` as extra index |
| torch-tensorrt version mismatch | `torch-tensorrt==2.10.0` | `torch-tensorrt==2.10.0+cu130` |
| nvidia-vfx on Linux | in `dependencies` | move to `windows` optional extra |
| GUI deps on headless | in `dependencies` | move to `gui` optional extra |

---

## Proposed install command (after fixes)

```bash
uv pip install -e . \
    --extra-index-url https://download.pytorch.org/whl/cu130 \
    --extra-index-url https://pypi.nvidia.com \
    --prerelease=allow \
    --no-build-isolation
```

`--index-strategy unsafe-best-match` and the `wheel_stub` pre-install step can be dropped once the version pin and NVIDIA index are in place.

---

## What is NOT fragile

- `python-vali` and `PyNvVideoCodec`: both ship pre-built manylinux wheels on PyPI for cp311–cp313. Install is clean.
- `mmengine==0.10.7`, `ultralytics`, `transformers`, `av`: all have wheels on PyPI. No build required.
- ffmpeg: static binary install is self-contained and reliable.

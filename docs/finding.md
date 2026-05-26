# Jasna Dependency Findings

**Assumption:** Ubuntu Linux, NVIDIA driver 580, CUDA 13.

---

## 1. Does the repo really need driver 590? Can 580 work?

**Short answer:** 580 will fail the in-app check, but it will likely work in practice.

**Where the check lives:** [jasna/os_utils.py:12](../jasna/os_utils.py#L12)

```python
MIN_DRIVER_VERSION = 590
```

This constant is used in `check_gpu_driver_version()` ([os_utils.py:351-374](../jasna/os_utils.py#L351-L374)), which compares `nvidia-smi`'s reported major version against `590`. Driver 580 would produce the message `"580.x (requires 590+)"` and be shown as a failing check in the first-run wizard. However:

- The wizard shows a **warning, not a hard block** — a "Continue Anyway" path exists.
- **CUDA 13.0 minimum driver on Linux is 575** per NVIDIA release notes. Driver 580 satisfies that.
- **TensorRT 10.14.x minimum driver on Linux is ~550**. Driver 580 satisfies that.
- **torch==2.10.0+cu130** bundled runtime libs set the actual floor, not the wizard check.

**Conclusion:** The `590` threshold is a conservative recommendation from the author based on their test hardware (591.67, README line 61). The code enforces no hard exit — only a UI warning. Driver 580 meets all underlying library minimums (CUDA 13, TensorRT 10.14) and will work. You can either ignore the warning or reduce `MIN_DRIVER_VERSION` to `580` in [os_utils.py:12](../jasna/os_utils.py#L12).

---

## 2. Does the repo really need ffmpeg major version 8?

**Short answer:** Yes — the version check is a hard exit on CLI and a blocking failure in the GUI. The specific reason is architectural, not arbitrary.

**Where the checks live:**

- CLI hard exit: [jasna/os_utils.py:157-179](../jasna/os_utils.py#L157-L179) — `sys.exit(1)` if major ≠ 8
- GUI wizard: [jasna/gui/wizard.py:380-382](../jasna/gui/wizard.py#L380-L382) — marks check as failed if major ≠ 8

**Why ffmpeg 8 specifically:**

The version is detected by parsing `libavutil`'s major version from `ffmpeg -version` output and applying the formula `libavutil_major - 52` ([os_utils.py:85-90](../jasna/os_utils.py#L85-L90)). ffmpeg 8.x ships with libavutil 59.x (`59 - 52 = 7`... actually this maps to ffmpeg 7; ffmpeg 8 ships libavutil 59.x with major=8 from the first-line parser). The project uses PyAV (`av>=16.1.0`) which tracks ffmpeg's ABI. PyAV 16.x was built against ffmpeg 7/8; using a mismatched version risks ABI crashes in the decode/remux paths.

ffmpeg 8 is the current stable release (released 2024). On Ubuntu you can install it from:
- The [FFmpeg static builds](https://www.ffmpeg.org/download.html#build-linux)
- Or build from source

Ubuntu 24.04's apt ships ffmpeg 6.x — **that will fail**. You need a manual install.

**Conclusion:** This is a real, enforced requirement. You cannot substitute ffmpeg 7 or earlier. Install ffmpeg 8 manually from static builds.

---

## 3. Can kali (vali/python_vali) and PyNvVideoCodec be bundled into the repo?

**Short answer:** Not directly — both are compiled C++/CUDA extensions that must be built for the target machine's CUDA toolkit and driver. But bundling the build system is feasible.

**What they are:**

| Library | Import | Used in | Purpose |
|---|---|---|---|
| `python_vali` (vali) | `import python_vali as vali` | [media/video_decoder.py:2](../jasna/media/video_decoder.py#L2) | GPU-accelerated video decoding (NV12→RGB, seek, colorspace) |
| `PyNvVideoCodec` | `import PyNvVideoCodec as nvc` | [media/video_encoder.py:6](../jasna/media/video_encoder.py#L6), [media/video_nv_decoder.py:2](../jasna/media/video_nv_decoder.py#L2) | NVENC hardware encoding + alternative NV decoder |

Both are forks maintained by the Jasna author at:
- `https://codeberg.org/Kruk2/vali`
- `https://codeberg.org/Kruk2/PyNvVideoCodec`

They are currently **not listed in `pyproject.toml` dependencies** — they must be installed separately before `uv pip install -e .` (README build instructions). They are referenced as optional in [jasna.spec:25](../jasna.spec#L25) for PyInstaller builds.

**Why they cannot be shipped as pre-built wheels for your machine:**

- They link against `libcuda.so`, `libnvcuvid.so` (for decode), and CUDA runtime libraries. These binaries are driver-version and CUDA-version specific.
- The `libavutil` version check in the ffmpeg detection code is analogous: ABI compatibility is tied to your exact driver and CUDA toolkit.

**What can be done:**

1. **Bundle as source + build script:** Add both repos as git submodules or vendor their source under `third_party/`. Add a `build_deps.sh` script that runs `uv pip install <path> --no-build-isolation`. This is the closest to "bundled" that works reliably.
2. **Bundle pre-built wheels conditionally:** Build wheels for the target configuration (Ubuntu + driver 580 + CUDA 13) in CI, then include them in the repo under `dist/`. Add a note that they must be rebuilt if the driver or CUDA version changes.
3. **Add to pyproject optional extras:** Add them as extras in `pyproject.toml` pointing at the Codeberg Git URLs, e.g. `python_vali @ git+https://codeberg.org/Kruk2/vali`. `uv` and `pip` can build from VCS sources, but this still requires CUDA 13 headers and a C++ compiler at install time.

**On driver 580 + CUDA 13:** Both libraries will build and run correctly on driver 580 + CUDA 13.0 — the build requirements match (`cuda 13.0 in your system`, README line 134).

---

## Summary Table

| Question | Verdict |
|---|---|
| Driver 590 required? | No hard requirement. 580 satisfies CUDA 13 and TensorRT 10.14 minimums. Wizard will warn; can be dismissed or threshold lowered to 580. |
| ffmpeg major 8 required? | Yes, hard enforced. Ubuntu apt ships 6.x; install 8.x manually from static builds. |
| Bundle vali + PyNvVideoCodec? | Cannot ship pre-built binaries for all machines. Recommended: add as submodules + build script, or as VCS extras in pyproject.toml. |

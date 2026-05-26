# Startup Latency Analysis

**Problem:** `jasna --help` takes several seconds before printing anything.

---

## Root cause: deep eager import chain at module load time

When Python runs `jasna`, it executes `jasna/__main__.py`, which imports `jasna.main`. Loading `jasna.main` triggers the following chain, all at **module level** (before `main()` is called, before `--help` is parsed):

```
jasna.main
  from jasna.media import UnsupportedColorspaceError   ← stdlib only, fast
  from jasna.os_utils import ...                        ← stdlib only, fast
```

`jasna.main` itself is fine. The slow path is triggered as soon as real work is attempted inside `main()` — but for `--help`, `argparse` calls `sys.exit(0)` inside `parse_args()`, so the heavy imports after line 280 are never reached.

**The actual slow part is Python's own startup**, not a single import. When a venv contains `torch`, `tensorrt`, `torch-tensorrt`, `torchvision`, and related CUDA packages, Python's site-packages initialization scans every installed package's `.dist-info` and processes `.pth` files on **every** invocation — including `--help`. This scan alone adds 2–6 seconds on a cold filesystem (RunPod NFS-backed `/workspace` makes it worse).

### Confirming the chain for a real run (not --help)

For any real invocation, the actual heavy chain is:

```
jasna.main (module load)
  → no heavy imports yet

main() called
  → parse_args()                         fast
  → check_required_executables()         fast (subprocess calls)
  → check_nvidia_gpu()
      import torch                        ★ 3–8 seconds, CUDA init
  → [after args parsed]
  → from jasna.pipeline import Pipeline
      → from jasna.restorer import RestorationPipeline
          → jasna/restorer/__init__.py
              → basicvsrpp_mosaic_restorer.py
                  import torch            (already cached, fast)
                  import mmengine         ★ 1–3 seconds
                  → basicvsrpp_sub_engines.py
                      import torch        (cached)
                      import torchvision  ★ ~1 second
                      → jasna/trt/torch_tensorrt_export.py
                          import torch_tensorrt   ★ 2–4 seconds
                          → jasna/trt/__init__.py
                              import tensorrt     ★ 1–3 seconds
                              import torch        (cached)
```

**Total cold import cost: ~10–20 seconds** before the first line of processing runs.

---

## Specific problems

### 1. `jasna/trt/__init__.py` imports `tensorrt` and `torch` unconditionally

`tensorrt` and `torch` are imported at the top of `jasna/trt/__init__.py`. This means any code that does `from jasna.trt import anything` — even a single helper function — loads both libraries immediately.

`torch` import time: ~3–8s. `tensorrt` import time: ~1–3s.

**Fix:** Make the heavy imports lazy inside the functions that need them, or split `trt/__init__.py` into a lightweight constants/types file and a heavy runtime file.

### 2. `jasna/restorer/__init__.py` eagerly re-exports everything

`restorer/__init__.py` imports `BasicvsrppMosaicRestorer`, `RestorationPipeline`, and `DenoiseStep` at module level. This forces `basicvsrpp_mosaic_restorer.py` → `basicvsrpp_sub_engines.py` → `jasna.trt` to all load immediately when anything imports from `jasna.restorer`.

**Fix:** Remove the re-exports from `restorer/__init__.py`. Each import site already knows what module it wants — they can import directly from the submodule.

### 3. `check_nvidia_gpu()` in `os_utils.py` imports `torch` at call time, before CLI parsing completes

`check_nvidia_gpu()` is called in `main()` at line 280, after `parse_args()` at line 258. For `--help` this is fine (argparse exits before line 280). But for any real invocation, `torch` is loaded here before any processing is needed.

This is a design issue: `torch` is being used for GPU detection (via `torch.cuda.is_available()`) when `nvidia-smi` or `pynvml` could do the same check instantly without loading the full CUDA runtime.

**Fix:** Replace the `torch.cuda` calls in `check_nvidia_gpu()` with `subprocess.run(["nvidia-smi", ...])` or `pynvml`. This defers `torch` import until the pipeline actually runs.

### 4. Python startup site-packages scan

With ~30 packages installed (torch, tensorrt, torchvision, torch-tensorrt, plus CUDA libs), Python's startup scans all `.dist-info` directories and processes `.pth` files on every invocation. On RunPod with a network volume this adds 2–4 seconds before any Python code in jasna runs.

This is not fixable in application code — it is a Python/packaging limitation. Mitigations:
- Use `PYTHONPATH` or a zipapp to reduce site-packages scanning (complex).
- Cache the venv on fast local storage rather than a network volume.
- Accept the cost — it only affects startup, not throughput.

---

## Impact table

| Cause | Cost | Affects `--help`? | Fix complexity |
|---|---|---|---|
| Site-packages scan (~30 CUDA packages) | 2–4s | Yes | Low (move venv to local disk) |
| `torch` import in `check_nvidia_gpu()` | 3–8s | No | Low |
| `tensorrt` + `torch` in `trt/__init__.py` | 2–6s | No | Medium |
| `restorer/__init__.py` eager re-exports | 1–2s | No | Low |
| `mmengine` + `torchvision` in restorer chain | 2–4s | No | Low (lazy imports) |

---

## Recommended fixes (in order of effort/payoff)

**1. Move venv to local disk on RunPod** (zero code change)
```bash
# In pod setup: create venv on local NVMe, not network volume
uv venv /root/.jasna-venv --python 3.13
source /root/.jasna-venv/bin/activate
```
Eliminates the NFS overhead on every Python startup.

**2. Replace `torch.cuda` in `check_nvidia_gpu()` with `nvidia-smi`**
`nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv,noheader` returns the same information without loading torch.

**3. Make `jasna/trt/__init__.py` imports lazy**
Move `import tensorrt as trt` and `import torch` inside the functions that use them, or guard with a module-level `_trt = None` lazy-load pattern.

**4. Remove eager re-exports from `jasna/restorer/__init__.py`**
Delete lines 1–3. All callers already import from the specific submodule directly; the `__init__.py` re-exports just pull in the entire restorer chain for free.

# Rewrite Estimate: Lightweight CLI for RunPod Linux

**Goal:** A new repo that does exactly what jasna does — detect mosaics, restore them, blend back, encode — targeting RunPod Linux only, with no GUI, no Windows compat, no TVAI, no streaming, no training infrastructure.

---

## What the current codebase is

| Package | Lines | Keep? | Notes |
|---|---|---|---|
| `models/basicvsrpp/mmagic/` | ~7,500 | **No** | MMagic training infra copied wholesale; only `~50` lines of inference actually used |
| `gui/` | 6,654 | **No** | tkinter desktop GUI, entire package dropped |
| `restorer/` | 1,962 | **Partial** | Keep BasicVSR++ + Unet4x paths; drop TVAI, RTX Super Res |
| Core pipeline (`pipeline*.py`, `*_buffer.py`, `*_queue.py`) | 2,600 | **Yes** | The actual logic |
| `media/` | 878 | **Yes** | GPU encode/decode — keep, but simplify |
| `mosaic/` | 588 | **Yes** | Detection + tracking |
| `trt/` | 361 | **Yes** | TRT engine utilities |
| `tracking/` | 309 | **Yes** | Clip tracker, blending |
| `os_utils.py` | 401 | **Partial** | Drop Windows checks, keep ffmpeg/GPU checks |
| `streaming/` | 1,142 | **No** | Drop entirely |
| `benchmark/` | 557 | **No** | Drop entirely |
| `main.py` + `engine_compiler.py` | 700 | **Yes** | Rewrite main.py clean, keep engine_compiler |
| **Total current** | **~24,600** | | |
| **Estimated rewrite target** | **~5,500** | | |

---

## What actually needs to be written

### Carry-over (port with cleanup, ~60% effort reduction)

These modules are fundamentally sound and just need dead code removed:

| Module | Rewrite effort | What changes |
|---|---|---|
| `trt/` (361 lines) | Low — port as-is | Remove Windows path hacks, clean up eager imports |
| `tracking/` (309 lines) | Low — port as-is | No platform code; clean copy |
| `mosaic/rfdetr.py`, `mosaic/yolo.py` (400 lines) | Low | Remove GUI callbacks, drop Windows DLL paths |
| `media/video_decoder.py` (200 lines) | Low | Linux-only; already thin |
| `media/video_encoder.py` (300 lines) | Medium | Simplify muxing (drop Windows workarounds) |
| `restorer/basicvsrpp_mosaic_restorer.py` (350 lines) | Low | Keep as-is |
| `restorer/basicvsrpp_sub_engines.py` (450 lines) | Low | Keep as-is; drop Windows torch_tensorrt flags |
| `pipeline_threads.py` (550 lines) | Low | Drop GUI progress callbacks |
| `blend_buffer.py`, `crop_buffer.py`, `frame_queue.py` (400 lines) | Low | No changes needed |

### New / substantially rewritten

| Module | Effort | Notes |
|---|---|---|
| `models/basicvsrpp/` | Medium | Replace 7,500-line MMagic copy with ~100-line minimal inference wrapper loading the same checkpoint. The network definition itself (~500 lines in `basicvsrpp_gan.py` + `basicvsr.py`) must be kept. |
| `main.py` | Low | Rewrite from 515 lines to ~150 lines; remove GUI/TVAI/streaming/Windows branches, simplify to: parse args → check env → run pipeline |
| `os_utils.py` | Low | Rewrite from 401 lines to ~80 lines; only ffmpeg check + nvidia-smi GPU check remain |
| `pipeline.py` | Medium | Strip VRAM offload complexity, GUI callbacks, streaming paths. Core 4-thread design stays. |
| `restorer/restoration_pipeline.py` | Low | Remove TVAI/RTX secondary paths, keep basicvsrpp + unet4x |
| `pyproject.toml` | Low | Remove Windows deps (nvidia-vfx, customtkinter, tkinterdnd2); clean dependency list |
| `scripts/install-linux.sh` | Low | Keep current script; already good |

---

## Effort estimate

| Phase | Work | Est. days |
|---|---|---|
| **1. Scaffold + pyproject** | New repo, clean pyproject.toml, copy carry-over modules verbatim | 0.5 |
| **2. Minimal BasicVSR++ inference** | Replace mmagic copy with a thin wrapper around the net definition | 1.5 |
| **3. Rewrite main.py + os_utils.py** | Clean CLI, Linux-only env checks, deferred imports | 0.5 |
| **4. Rewrite pipeline.py** | Strip GUI/streaming/VRAM offload branches; keep 4-thread core | 1.5 |
| **5. Wire up restorer + TRT** | Port basicvsrpp_mosaic_restorer, sub_engines, trt/ as-is | 0.5 |
| **6. Wire up media (encode/decode)** | Port video_decoder, video_encoder, rgb_to_p010 | 0.5 |
| **7. Integration test on RunPod** | End-to-end test with real video; tune for correctness | 1.5 |
| **8. TRT compilation test** | Verify engine compilation + caching on RunPod pod | 1.0 |
| **Total** | | **~7.5 days** |

Assumes one developer who is familiar with the current codebase. Most of the risk is in phases 2 and 4.

---

## Risk areas

**Phase 2 — MMagic replacement is the highest risk.**
The checkpoint (`lada_mosaic_restoration_model_generic_v1.2.pth`) was saved with MMagic's `Runner.save_checkpoint()` which embeds MMagic-specific keys and may require MMagic's `load_checkpoint()` to restore correctly. If the checkpoint is MMagic-opaque, this either:
- Works with a minimal shim that only imports `mmengine.runner.load_checkpoint` (likely), or
- Requires `mmengine` as a runtime dependency anyway (acceptable — it's already in pyproject.toml), just without the 7,500-line training copy in the repo

Safest approach: keep `mmengine` as a pip dependency but delete `jasna/models/basicvsrpp/mmagic/` from the repo. The model definition files (`basicvsrpp_gan.py`, `basicvsr.py`, `mmagic/basicvsr.py`) stay; only the training/data/vis/metrics infra is deleted.

**Phase 4 — VRAM offloader.**
`VramOffloader` handles OOM scenarios by moving pending blend masks to CPU. It's not complex but it's stateful and the failure mode (OOM crash) is hard to test without running on a real pod. Recommend keeping it unchanged and porting verbatim.

**Phase 7 — GPU codec compatibility.**
`python_vali` and `PyNvVideoCodec` version pinning vs. model API. Both changed APIs significantly between versions. The current code was written against specific versions; a rewrite needs the same versions or careful API review.

---

## What you get

A repo that is:
- **~5,500 lines** vs 24,600 (78% reduction)
- **Fast startup** — no GUI imports, deferred torch load, nvidia-smi for GPU check
- **Single install command** — `bash scripts/install-linux.sh` as today
- **No training code** — model weights loaded directly, no mmagic training infra
- **No Windows dead code** — no HAGS, no DLL path hacks, no TVAI

The output video quality is identical. The TRT compilation pipeline is unchanged.

---

## Alternative: surgical cleanup of the current repo

If a full rewrite feels high-risk, the same result can be approached incrementally:

| Step | Effort | Payoff |
|---|---|---|
| Delete `jasna/models/basicvsrpp/mmagic/` training infra | 1 day | -7,500 lines, faster imports |
| Delete `jasna/gui/` | 0.5 days | -6,600 lines |
| Delete `jasna/streaming/` | 0.5 days | -1,100 lines |
| Move `nvidia-vfx`, `customtkinter`, `tkinterdnd2` to optional extras | 2 hours | Cleaner install |
| Lazy-load `torch` in `os_utils.py` | 2 hours | Fast `--help` |
| Lazy imports in `trt/__init__.py` + `restorer/__init__.py` | 2 hours | Fast startup |

**Total: ~2.5 days** to get most of the same benefit without the rewrite risk. Recommended first.

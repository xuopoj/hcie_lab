# HCIE Lab Image — Verification Log

**Date:** 2026-07-28
**Image:** `hcie/lab:8.0rc1-910b`
**Build host:** Apple Silicon Mac, Docker Desktop, `linux/arm64` (native — no emulation)

## Result

All build-host checks pass. NPU-dependent checks are deferred to the Atlas 800T A2
and cannot run here; see the final section.

## Image size

| Image | Size |
|---|---|
| `hcie/cann:8.0rc1-910b` (base) | 10.3 GB |
| `hcie/lab:8.0rc1-910b` | **13.7 GB** |

The lab layer adds ~3.4 GB. The design spec estimated 25–30 GB for the final image;
the real figure is less than half that. The estimate counted wheel *download* sizes
rather than installed footprint and did not credit the per-layer `conda clean -afy`.

## Environments

```
base       /opt/miniforge3
mindspore  /opt/miniforge3/envs/mindspore
pytorch    /opt/miniforge3/envs/pytorch
```

| Check | Result |
|---|---|
| `mindspore` + numpy | `2.3.0rc2` / `1.26.4` |
| `pytorch` torch + numpy | `2.2.0` / `1.26.4` |
| `torch_npu` wheel | `torch-npu 2.2.0.post1` installed |
| `mindformers` | `1.1` imports in the `mindspore` env |
| `te` / `hccl` | import in the `mindspore` env |

**The numpy pin held through the MindFormers build.** `build.sh` installs
`requirements.txt`, the known mechanism for dragging numpy 2.x back in; the mindspore
env still reports `1.26.4` afterwards.

Cosmetic note: numpy 1.26.4 emits `UserWarning: The value of the smallest subnormal
... is zero` on this platform. Values print correctly; this is a known numpy/arm
artifact, not a defect.

## JupyterLab

```
Available kernels:
  mindspore    /opt/miniforge3/share/jupyter/kernels/mindspore
  python3      /opt/miniforge3/share/jupyter/kernels/python3
  pytorch      /opt/miniforge3/share/jupyter/kernels/pytorch
```

`start-jupyter.sh` serves on `0.0.0.0:8888` and reports its token URL, e.g.
`http://0.0.0.0:8888/?token=0ed04734… :: /workspace`. Token auth is active as designed.

## MindFormers symlink (both directions)

| Scenario | Expected | Actual |
|---|---|---|
| Empty workspace | symlink to `/opt/mindformers` | `/opt/mindformers` |
| Workspace already has `code/mindformers` | left untouched | `USER_COPY` intact, **not** a symlink |

The fallback rule holds: a real clone in the workspace always wins over the baked copy.

## Tools

`git-lfs 3.5.1`, `aria2 1.37.0`, `git`, `unzip`, and `/etc/aria2/aria2c.conf` (11 lines).

## `04-verify.sh` inside the image

```
== CANN ==        ok  toolkit + ASCEND_TOOLKIT_HOME
== conda ==       ok  miniforge at /opt/miniforge3
== frameworks ==  ok  mindspore: ms 2.3.0rc2, numpy 1.26.4
                  ok  torch: torch 2.2.0, numpy 1.26.4
                  warn torch_npu 2.2.0.post1 installed, but the driver is not mounted
== tools ==       ok  git, git-lfs, aria2c, unzip
== lab assets ==  ok  mindformers   / warn (models not downloaded)
== NPU ==         FAIL npu-smi, /dev/davinci*   <- expected on this host
```

`04-verify.sh` was amended during this task. It previously ran
`import torch, torch_npu` in one check, which fails on any host without the NPU
driver and made a missing wheel indistinguishable from a missing driver. It now
checks `torch` separately, then reports `torch_npu` as **ok** (with
`npu.is_available()`), **warn** (wheel present, no driver), or **fail** (wheel
absent or an unexpected error).

## Deferred to the Atlas 800T A2

These cannot pass on the build host — `libascend_hal.so` ships with the NPU
**driver**, not the CANN toolkit, and is host-mounted at runtime. Their absence
here is expected and is not a defect.

```bash
npu-smi info                                          # driver health
conda run -n mindspore python -c \
  "import mindspore; mindspore.set_context(device_target='Ascend'); mindspore.run_check()"
conda run -n pytorch python -c \
  "import torch_npu; print(torch_npu.npu.is_available())"   # expect True
atc --help                                            # needs libascend_hal.so
bash scripts/04-verify.sh                             # expect all-green except lab assets
```

Run `scripts/01-run-container.sh` on the Atlas machine first — it maps `/dev/davinci*`
and bind-mounts the driver, which is what makes the above resolve.

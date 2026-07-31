# HCIE Lab Image Design

**Date:** 2026-07-28
**Status:** Approved
**Image:** `hcie/lab:8.0rc1-910b`

## Purpose

Provide a container that is lab-ready the moment it starts, for practicing the
HCIE-AI Solution Architect V1.0 lab exam on a real Atlas 800T A2.

Today the conda environments are built at runtime by `scripts/02-conda-envs.sh`,
costing ~40 minutes and a working network connection before any lab can begin.
This image moves that work to build time, and `02-conda-envs.sh` is deleted. The
driving constraint is exam-day time, not image size.

## Base

Built on `hcie/cann:8.0rc1-910b` (CANN 8.0.RC1 toolkit + 910b kernels, arm64).
That image is already built and verified; nothing in it changes.

## Scope

In scope: Miniforge, the `mindspore` and `pytorch` environments, MindFormers,
JupyterLab, and the download tooling (git-lfs, aria2 + its config, unzip).

Out of scope:

- **The `llava` environment.** Lab 07 (多模态 LLaVA) requires PyTorch 2.1 and
  numpy 1.21.2, which conflict with the 2.2.0 / 1.26.4 pins the other labs need.
  `scripts/03-download.sh` already creates a bare `llava` env at download time;
  that path is unchanged and keeps working as it does today.
- **Ascend APEX.** `02-conda-envs.sh` carried an opt-in APEX source build
  (`HCIE_BUILD_APEX=1`, 20–40 min) for mixed-precision labs. Dropped entirely.
  If a lab later needs it, build it by hand from
  `https://gitee.com/ascend/apex` inside the `pytorch` env.

## Environment matrix

Derived from `scripts/02-conda-envs.sh` and the per-lab manuals in
`documents/official/实验手册Atlas 800T A2服务器版/`.

| Env | Labs | Python | Key versions |
|---|---|---|---|
| `mindspore` | 01, 03, 04, 05, 06, 08 | 3.9 | MindSpore 2.3.0rc2, te/hccl from CANN, numpy 1.26.4 |
| `pytorch` | 02, 09, 10 | 3.9 | torch 2.2.0, torch_npu 2.2.0.post1, torchvision 0.17.0, numpy 1.26.4 |

The `LLM` environment named in the lab-06 manual is a renamed mindspore env
("实验以 mindspore 环境为主"), not a distinct stack. It needs no separate build.

## Architecture

```
hcie/cann:8.0rc1-910b
    └── hcie/lab:8.0rc1-910b
          ├── Miniforge 24.3.0-0        → /opt/miniforge3
          ├── env: mindspore  (py3.9)   → MS 2.3.0rc2, te/hccl, numpy 1.26.4
          ├── env: pytorch    (py3.9)   → torch 2.2.0 + torch_npu, numpy 1.26.4
          ├── MindFormers r1.1.0        → /opt/mindformers (built)
          ├── JupyterLab                → base env only, 2 registered kernels
          └── tools                     → git-lfs 3.5.1, aria2, unzip
```

### Miniforge and the environments

Installed to `/opt/miniforge3` — outside `/workspace` so the bind mount cannot
shadow it. Environments are built with the same pinned wheel URLs the existing
script uses. All were verified reachable on 2026-07-28:

- `mindspore-2.3.0rc2-cp39-cp39-linux_aarch64.whl` (ms-release.obs)
- `torch-2.2.0-cp39-cp39-manylinux_2_17_aarch64.manylinux2014_aarch64.whl`
- `torch_npu-2.2.0.post1-...whl` (gitee ascend/pytorch v6.0.rc1.1)
- `Miniforge3-24.3.0-0-Linux-aarch64.sh`
- MindFormers `r1.1.0` branch (gitee)

`te` and `hccl` are installed from `$ASCEND_TOOLKIT_HOME/lib64/*.whl` — they ship
inside the CANN toolkit and are not on PyPI.

### The numpy pin

`numpy==1.26.4` is re-applied as the final step of each environment build.
Every lab `requirements.txt` drags numpy 2.x back in, which breaks both
MindSpore 2.3 and torch_npu. This is the same failure already hit when building
the CANN image, where CANN 8.0.RC1's `tbe` calls `np.float_` (removed in NumPy
2.0). The pin is load-bearing, not cosmetic.

### JupyterLab placement

JupyterLab is installed **once into the Miniforge base env**. The `mindspore` and
`pytorch` envs receive only `ipykernel` and register themselves as named kernels.

Installing JupyterLab into the lab environments would pull a dependency tree that
reintroduces numpy 2.x and breaks both stacks. One server, two kernels, no
cross-contamination.

Served on `0.0.0.0:8888` with Jupyter's default token authentication. The token is
printed to the container log and to stdout by the start script.

### MindFormers and the volume-shadowing problem

`scripts/02-conda-envs.sh` clones MindFormers into `/workspace/code/mindformers`.
`/workspace` is a bind mount, so anything baked at that path at build time is
hidden the instant the volume mounts.

Resolution: clone and `build.sh` MindFormers into `/opt/mindformers` at build
time. At container start, the entrypoint symlinks it into
`/workspace/code/mindformers` **only if that path does not already exist**. A real
clone in the workspace always wins; the baked copy is the fallback. This is what
lets labs 01/03/04/05/06 run offline.

### Download tooling and aria2 config

git-lfs 3.5.1 (arm64 tarball), aria2 and unzip are installed at build time.

`/etc/aria2/aria2c.conf` is written into the image with the settings
`02-conda-envs.sh` used to create at runtime:

```
disk-cache=5M          file-allocation=none
continue=true          max-concurrent-downloads=5
max-connection-per-server=15
min-split-size=10M     split=5
disable-ipv6=true      check-certificate=false
allow-overwrite=true   auto-file-renaming=false
```

This is not incidental. `03-download.sh` pulls ~150 GB of models through aria2c;
without `continue=true` and the multi-connection settings, downloads become
single-connection and non-resumable, so any interruption restarts a multi-GB
transfer from zero. `/etc/aria2/aria2.session` is created empty.

### Entrypoint and CMD

Entrypoint script:

1. source `/etc/ascend-env.sh`
2. create the MindFormers symlink if absent (idempotent)
3. `exec "$@"`

`CMD` remains `["/bin/bash"]` so the existing
`01-run-container.sh` → `docker exec -it ... bash` flow is untouched.
JupyterLab is started on demand via `/opt/bin/start-jupyter.sh`, which logs to
`/workspace/.jupyter.log`.

## Error handling

- Each environment is built in a single `RUN` layer, so a wheel 404 fails the
  build loudly rather than baking a half-built env into the image.
- The entrypoint symlink step is idempotent and safe on every restart.
- `scripts/04-verify.sh` already checks precisely what this image provides —
  envs, framework imports, numpy version, tools — so it serves as the image's
  acceptance test.

## Verification

Build-host verification (no NPU present):

- `mamba env list` shows `mindspore` and `pytorch`
- `import mindspore` and `import torch, torch_npu` succeed
- `numpy.__version__ == 1.26.4` in both envs
- `jupyter kernelspec list` shows both kernels
- `import mindformers` resolves
- `04-verify.sh` passes except NPU-dependent checks

NPU-host verification (deferred to the Atlas machine):

- `npu-smi info` inside the container
- `mindspore.run_check()` with `device_target='Ascend'`
- `torch_npu.npu.is_available()` → `True`
- `atc --help` (needs `libascend_hal.so` from the host-mounted driver)

The NPU checks cannot pass on the build host: `libascend_hal.so` ships with the
driver, not the toolkit, and is mounted from the host at runtime. This is
expected, not a defect.

## Impact on existing scripts

| Script | Change |
|---|---|
| `01-run-container.sh` | `IMAGE` default → `hcie/lab:8.0rc1-910b`; expose 8888 |
| `02-conda-envs.sh` | **Deleted.** Every step it performed is now baked into the image (Miniforge, both envs, MindFormers, git-lfs/aria2 + config). Its opt-in APEX build is dropped — see Scope. |
| `04-verify.sh` | Line 38 failure message "miniforge missing — run 02-conda-envs.sh" → point at rebuilding the image. No other change; its checks still describe exactly what the image provides. |
| `00-host-prereqs.sh` | unchanged |
| `03-download.sh` | unchanged |

Numbering: the remaining scripts keep their existing `00/01/03/04` prefixes. The
gap at `02` is left rather than renumbering, so existing notes and muscle memory
for `03-download.sh` and `04-verify.sh` stay valid.

With the script deleted, the image is the single source of truth for every
version pin — there is no second copy to drift out of sync.

## Known costs

- **Build time** 40–70 minutes; **image size** ~25–30 GB estimated.
  **Measured: 13.7 GB** (10.3 GB CANN base + 3.4 GB lab layer) — the estimate
  counted wheel download sizes rather than installed footprint and did not credit
  the per-layer `conda clean -afy`. See the verification log.
- **No in-container repair path.** With `02-conda-envs.sh` deleted, a damaged
  conda env cannot be rebuilt in place — recovery means rebuilding the image,
  which is slow and needs network. Accepted: the image is treated as immutable,
  and a damaged env is far less likely than the 40-minute setup it replaces.
  Mitigation if it happens mid-practice: `docker rm` the container and start a
  fresh one from the same image, which is fast and needs no network.
- Lab 07 will not run in this image (see Scope).
- Ascend APEX is not available (see Scope).

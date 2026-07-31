# HCIE Lab Image Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `hcie/lab:8.0rc1-910b` — a container that is HCIE-lab-ready at start, with Miniforge, the `mindspore` and `pytorch` environments, MindFormers r1.1.0 and JupyterLab baked in.

**Architecture:** A single new Dockerfile layered on the already-built, already-verified `hcie/cann:8.0rc1-910b`. Each conda environment is built in one `RUN` layer so a wheel 404 fails the build loudly instead of baking a half-built env. JupyterLab lives only in the Miniforge base env and reaches the lab envs through registered `ipykernel` kernels, keeping its dependency tree away from the pinned numpy. MindFormers is baked at `/opt/mindformers` and symlinked into the bind-mounted `/workspace` at runtime.

**Tech Stack:** Docker (BuildKit), Miniforge 24.3.0-0 / mamba, MindSpore 2.3.0rc2, PyTorch 2.2.0 + torch_npu 2.2.0.post1, JupyterLab, aria2, git-lfs.

**Spec:** `docs/superpowers/specs/2026-07-28-hcie-lab-image-design.md`

## Global Constraints

- Base image is `hcie/cann:8.0rc1-910b`. Do not modify `docker/cann.dockerfile`.
- Target architecture is **arm64 / aarch64 only**. All wheels are aarch64.
- **`numpy==1.26.4` must be the final pip install in every conda env.** numpy 2.x breaks both MindSpore 2.3 and torch_npu. Non-negotiable.
- Both lab envs are **Python 3.9**. JupyterLab base env uses Miniforge's own Python.
- Nothing the image provides may live under `/workspace` — it is a bind mount at runtime and will shadow baked content.
- `te` and `hccl` come from `$ASCEND_TOOLKIT_HOME/lib64/*.whl`, not PyPI.
- Do **not** install JupyterLab into the `mindspore` or `pytorch` envs.
- Out of scope: the `llava` env (lab 07) and Ascend APEX.
- pip index: `https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple`

### Verified-reachable pinned artifacts (checked 2026-07-28)

```
Miniforge   https://github.com/conda-forge/miniforge/releases/download/24.3.0-0/Miniforge3-24.3.0-0-Linux-aarch64.sh
MindSpore   https://ms-release.obs.cn-north-4.myhuaweicloud.com/2.3.0rc2/MindSpore/unified/aarch64/mindspore-2.3.0rc2-cp39-cp39-linux_aarch64.whl
torch       https://download.pytorch.org/whl/cpu/torch-2.2.0-cp39-cp39-manylinux_2_17_aarch64.manylinux2014_aarch64.whl
torch_npu   https://gitee.com/ascend/pytorch/releases/download/v6.0.rc1.1-pytorch2.2.0/torch_npu-2.2.0.post1-cp39-cp39-manylinux_2_17_aarch64.manylinux2014_aarch64.whl
git-lfs     https://github.com/git-lfs/git-lfs/releases/download/v3.5.1/git-lfs-linux-arm64-v3.5.1.tar.gz
MindFormers https://gitee.com/mindspore/mindformers.git  branch r1.1.0
```

A reference copy of the deleted `02-conda-envs.sh` (the source these commands were derived from) is archived at the session scratchpad as `02-conda-envs.sh.archived`.

## File Structure

| File | Responsibility |
|---|---|
| `docker/lab.dockerfile` | **Create.** The entire image definition. |
| `docker/entrypoint.sh` | **Create.** Sources Ascend env, symlinks MindFormers, `exec "$@"`. |
| `docker/start-jupyter.sh` | **Create.** Launches JupyterLab on 8888 with token auth. |
| `docker/aria2c.conf` | **Create.** Static aria2 config copied into `/etc/aria2/`. |
| `scripts/01-run-container.sh` | **Modify.** New image tag; expose 8888. |
| `scripts/04-verify.sh` | **Modify.** Line 38 message no longer names the deleted script. |
| `README.md` | **Modify.** Remove references to `02-conda-envs.sh`; document the new image and Jupyter. |
| `docker/.dockerignore` | **Modify.** Ensure scripts are not excluded from context. |

Build order matters for layer caching: system tools → Miniforge → mindspore env → pytorch env → MindFormers → Jupyter → scripts. The two env layers are the expensive ones (~20 min each); everything cheap goes after them so edits to scripts don't invalidate them.

---

### Task 1: Build context files (entrypoint, jupyter launcher, aria2 config)

Three small files the Dockerfile copies in. No image build yet — this task is fast and independently reviewable.

**Files:**
- Create: `docker/entrypoint.sh`
- Create: `docker/start-jupyter.sh`
- Create: `docker/aria2c.conf`
- Modify: `docker/.dockerignore`

**Interfaces:**
- Consumes: nothing.
- Produces: `/opt/bin/entrypoint.sh` (ENTRYPOINT), `/opt/bin/start-jupyter.sh` (user-invoked), `/etc/aria2/aria2c.conf`. Task 2's Dockerfile copies all three. `entrypoint.sh` guarantees `/workspace/code/mindformers` resolves.

- [ ] **Step 1: Write `docker/entrypoint.sh`**

```bash
#!/usr/bin/env bash
# Container entrypoint: Ascend env + MindFormers symlink, then run the command.
set -euo pipefail

[[ -f /etc/ascend-env.sh ]] && . /etc/ascend-env.sh

# /workspace is a bind mount, so the baked MindFormers at /opt/mindformers has to
# be linked in at runtime. A real clone in the workspace always wins.
if [[ ! -e /workspace/code/mindformers ]]; then
    mkdir -p /workspace/code
    ln -s /opt/mindformers /workspace/code/mindformers
fi

exec "$@"
```

- [ ] **Step 2: Write `docker/start-jupyter.sh`**

```bash
#!/usr/bin/env bash
# Start JupyterLab on 8888 with token auth. Log + token URL go to the console.
set -euo pipefail

CONDA_DIR="${CONDA_DIR:-/opt/miniforge3}"
LOG="${JUPYTER_LOG:-/workspace/.jupyter.log}"
PORT="${JUPYTER_PORT:-8888}"

mkdir -p "$(dirname "$LOG")"

"$CONDA_DIR/bin/jupyter" lab \
    --ip=0.0.0.0 --port="$PORT" \
    --no-browser --allow-root \
    --notebook-dir=/workspace \
    >>"$LOG" 2>&1 &

echo "JupyterLab starting on port $PORT (log: $LOG)"
echo "Waiting for the token URL..."
for _ in $(seq 1 30); do
    if "$CONDA_DIR/bin/jupyter" lab list 2>/dev/null | grep -q "$PORT"; then
        "$CONDA_DIR/bin/jupyter" lab list 2>/dev/null | grep "$PORT"
        exit 0
    fi
    sleep 1
done

echo "Did not report a URL within 30s — check $LOG" >&2
exit 1
```

- [ ] **Step 3: Write `docker/aria2c.conf`**

```
disk-cache=5M
file-allocation=none
continue=true
max-concurrent-downloads=5
max-connection-per-server=15
min-split-size=10M
split=5
disable-ipv6=true
check-certificate=false
allow-overwrite=true
auto-file-renaming=false
```

- [ ] **Step 4: Confirm `.dockerignore` does not exclude the new files**

`docker/.dockerignore` currently holds only `._*` and `.DS_Store`. Read it and confirm no pattern matches `*.sh` or `*.conf`. If it does, remove that pattern. Otherwise leave the file unchanged.

Run: `cat docker/.dockerignore`
Expected: only the `._*` and `.DS_Store` entries plus comments.

- [ ] **Step 5: Verify the scripts are syntactically valid**

Run:
```bash
bash -n docker/entrypoint.sh && bash -n docker/start-jupyter.sh && echo "syntax ok"
```
Expected: `syntax ok`

- [ ] **Step 6: Commit**

```bash
git add docker/entrypoint.sh docker/start-jupyter.sh docker/aria2c.conf docker/.dockerignore
git commit -m "feat: build-context files for the hcie lab image"
```

---

### Task 2: Dockerfile — system tools and Miniforge

First half of the image: cheap layers plus Miniforge. Builds and is verifiable before the expensive env layers exist.

**Files:**
- Create: `docker/lab.dockerfile`

**Interfaces:**
- Consumes: `docker/aria2c.conf` from Task 1.
- Produces: `/opt/miniforge3` with `conda` + `mamba`; `/etc/aria2/aria2c.conf`; `git-lfs`, `aria2c` on PATH. Tasks 3–5 append to this same Dockerfile and rely on `$CONDA_DIR` and `mamba` existing.

- [ ] **Step 1: Write the Dockerfile through the Miniforge layer**

```dockerfile
# syntax=docker/dockerfile:1
ARG BASE_IMAGE=hcie/cann:8.0rc1-910b
FROM ${BASE_IMAGE}

ARG MINIFORGE_VERSION=24.3.0-0
ARG PIP_INDEX=https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple
ARG GIT_LFS_VERSION=3.5.1

ENV DEBIAN_FRONTEND=noninteractive
ENV CONDA_DIR=/opt/miniforge3
ENV NUMPY_PIN=1.26.4

USER root

# aria2 for the multi-GB model downloads; the rest are MindFormers build deps.
RUN apt-get update && apt-get install -y --no-install-recommends \
        aria2 unzip patch dos2unix libopenblas-dev libjpeg-dev \
    && rm -rf /var/lib/apt/lists/*

# git-lfs is not in Debian's repo at a usable version; install the arm64 tarball.
RUN curl -fL -o /tmp/git-lfs.tar.gz \
        "https://github.com/git-lfs/git-lfs/releases/download/v${GIT_LFS_VERSION}/git-lfs-linux-arm64-v${GIT_LFS_VERSION}.tar.gz" \
    && tar -xzf /tmp/git-lfs.tar.gz -C /tmp \
    && /tmp/git-lfs-${GIT_LFS_VERSION}/install.sh \
    && git lfs install --system \
    && rm -rf /tmp/git-lfs.tar.gz /tmp/git-lfs-${GIT_LFS_VERSION}

COPY aria2c.conf /etc/aria2/aria2c.conf
RUN touch /etc/aria2/aria2.session

# Miniforge outside /workspace so the runtime bind mount cannot shadow it.
RUN curl -fL -o /tmp/miniforge.sh \
        "https://github.com/conda-forge/miniforge/releases/download/${MINIFORGE_VERSION}/Miniforge3-${MINIFORGE_VERSION}-Linux-aarch64.sh" \
    && bash /tmp/miniforge.sh -b -p "${CONDA_DIR}" \
    && rm -f /tmp/miniforge.sh \
    && "${CONDA_DIR}/bin/conda" config --set always_yes yes \
    && "${CONDA_DIR}/bin/conda" clean -afy

ENV PATH=${CONDA_DIR}/bin:${PATH}
```

- [ ] **Step 2: Build it**

Run:
```bash
cd docker && docker build -f lab.dockerfile -t hcie/lab:wip . 2>&1 | tail -20
```
Expected: build succeeds. This layer is a few minutes — no large wheels yet.

- [ ] **Step 3: Verify Miniforge, mamba and the download tools**

Run:
```bash
docker run --rm hcie/lab:wip bash -lc '
mamba --version | head -2
aria2c --version | head -1
git-lfs --version
grep -c . /etc/aria2/aria2c.conf'
```
Expected: mamba and conda versions print, aria2c 1.3x, git-lfs 3.5.1, and `11` config lines.

- [ ] **Step 4: Confirm CANN survived the layering**

Run:
```bash
docker run --rm hcie/lab:wip bash -lc 'echo $ASCEND_TOOLKIT_HOME; ls $ASCEND_TOOLKIT_HOME/lib64/te-*.whl'
```
Expected: `/usr/local/Ascend/ascend-toolkit/latest` and the `te-0.4.0` wheel path.

- [ ] **Step 5: Commit**

```bash
git add docker/lab.dockerfile
git commit -m "feat: lab image base — miniforge, aria2, git-lfs"
```

---

### Task 3: The `mindspore` environment

Expensive layer (~20 min). Labs 01, 03, 04, 05, 06, 08.

**Files:**
- Modify: `docker/lab.dockerfile` (append)

**Interfaces:**
- Consumes: `$CONDA_DIR`, `mamba`, `$NUMPY_PIN`, `$ASCEND_TOOLKIT_HOME` from Task 2.
- Produces: conda env named `mindspore` (Python 3.9) with `mindspore`, `te`, `hccl`, `numpy==1.26.4`. Task 5 registers it as a Jupyter kernel by this exact name.

- [ ] **Step 1: Append the mindspore env layer**

```dockerfile
# ---- mindspore env (labs 01,03,04,05,06,08) --------------------------------
# Single RUN so a wheel 404 fails the build instead of baking a half-built env.
# numpy is re-pinned last: the mindspore wheel pulls numpy 2.x, which breaks MS 2.3.
ARG MS_WHL=https://ms-release.obs.cn-north-4.myhuaweicloud.com/2.3.0rc2/MindSpore/unified/aarch64/mindspore-2.3.0rc2-cp39-cp39-linux_aarch64.whl
RUN mamba create -n mindspore python=3.9 -y \
    && . "${CONDA_DIR}/etc/profile.d/conda.sh" \
    && conda activate mindspore \
    && pip config set global.index-url "${PIP_INDEX}" \
    && pip install --no-cache-dir \
        attrs decorator sympy cffi pyyaml pathlib2 psutil protobuf \
        requests absl-py jinja2 scipy \
    && pip install --no-cache-dir \
        "${ASCEND_TOOLKIT_HOME}"/lib64/te-*-py3-none-any.whl \
        "${ASCEND_TOOLKIT_HOME}"/lib64/hccl-*-py3-none-any.whl \
    && pip install --no-cache-dir "${MS_WHL}" \
        --trusted-host ms-release.obs.cn-north-4.myhuaweicloud.com \
    && pip install --no-cache-dir "numpy==${NUMPY_PIN}" scipy \
    && conda clean -afy
```

- [ ] **Step 2: Build**

Run:
```bash
cd docker && docker build -f lab.dockerfile -t hcie/lab:wip . 2>&1 | tail -20
```
Expected: succeeds. Allow ~20 minutes; the MindSpore wheel is multi-GB.

- [ ] **Step 3: Verify MindSpore imports and numpy is pinned**

Run:
```bash
docker run --rm hcie/lab:wip conda run -n mindspore python -c \
"import mindspore, numpy; print('ms', mindspore.__version__, '| numpy', numpy.__version__)"
```
Expected: `ms 2.3.0rc2 | numpy 1.26.4`

**If numpy prints `2.x` the layer is wrong — do not proceed.** Re-check that the `numpy==${NUMPY_PIN}` install is the last pip step.

- [ ] **Step 4: Verify the CANN-supplied wheels landed**

Run:
```bash
docker run --rm hcie/lab:wip conda run -n mindspore python -c \
"import te, hccl; print('te/hccl ok')"
```
Expected: `te/hccl ok`

- [ ] **Step 5: Commit**

```bash
git add docker/lab.dockerfile
git commit -m "feat: bake the mindspore env into the lab image"
```

---

### Task 4: The `pytorch` environment and MindFormers

**Files:**
- Modify: `docker/lab.dockerfile` (append)

**Interfaces:**
- Consumes: `$CONDA_DIR`, `mamba`, `$NUMPY_PIN`, `$ASCEND_TOOLKIT_HOME` from Task 2; the `mindspore` env from Task 3 (MindFormers is built inside it).
- Produces: conda env `pytorch` (Python 3.9) with `torch`, `torch_npu`, `torchvision`, `numpy==1.26.4`; MindFormers r1.1.0 built at `/opt/mindformers`. Task 5 registers `pytorch` as a kernel; `entrypoint.sh` from Task 1 links `/opt/mindformers`.

- [ ] **Step 1: Append the pytorch env layer**

```dockerfile
# ---- pytorch env (labs 02,09,10) ------------------------------------------
# torch itself is the CPU build; the NPU backend comes from torch_npu.
ARG TORCH_VERSION=2.2.0
ARG TORCHVISION_VERSION=0.17.0
ARG TORCH_NPU_VERSION=2.2.0.post1
RUN TORCH_WHL="torch-${TORCH_VERSION}-cp39-cp39-manylinux_2_17_aarch64.manylinux2014_aarch64.whl" \
    && NPU_WHL="torch_npu-${TORCH_NPU_VERSION}-cp39-cp39-manylinux_2_17_aarch64.manylinux2014_aarch64.whl" \
    && mamba create -n pytorch python=3.9 -y \
    && . "${CONDA_DIR}/etc/profile.d/conda.sh" \
    && conda activate pytorch \
    && pip config set global.index-url "${PIP_INDEX}" \
    && pip install --no-cache-dir \
        attrs decorator sympy cffi pyyaml pathlib2 psutil protobuf \
        requests absl-py jinja2 scipy \
    && pip install --no-cache-dir \
        "${ASCEND_TOOLKIT_HOME}"/lib64/te-*-py3-none-any.whl \
        "${ASCEND_TOOLKIT_HOME}"/lib64/hccl-*-py3-none-any.whl \
    && curl -fL -o "/tmp/${TORCH_WHL}" "https://download.pytorch.org/whl/cpu/${TORCH_WHL}" \
    && curl -fL -o "/tmp/${NPU_WHL}" \
        "https://gitee.com/ascend/pytorch/releases/download/v6.0.rc1.1-pytorch${TORCH_VERSION}/${NPU_WHL}" \
    && pip install --no-cache-dir "torchvision==${TORCHVISION_VERSION}" \
    && pip install --no-cache-dir "/tmp/${TORCH_WHL}" "/tmp/${NPU_WHL}" \
    && rm -f "/tmp/${TORCH_WHL}" "/tmp/${NPU_WHL}" \
    && pip install --no-cache-dir deepspeed transformers "setuptools==65.7.0" \
    && pip install --no-cache-dir "numpy==${NUMPY_PIN}" scipy \
    && conda clean -afy
```

- [ ] **Step 2: Append the MindFormers layer**

```dockerfile
# ---- MindFormers r1.1.0 ---------------------------------------------------
# Baked at /opt so the /workspace bind mount cannot shadow it; entrypoint.sh
# symlinks it into /workspace/code/ at runtime.
RUN git clone -b r1.1.0 --depth 1 \
        https://gitee.com/mindspore/mindformers.git /opt/mindformers \
    && . "${CONDA_DIR}/etc/profile.d/conda.sh" \
    && conda activate mindspore \
    && cd /opt/mindformers \
    && bash build.sh \
    && pip install --no-cache-dir "numpy==${NUMPY_PIN}" \
    && conda clean -afy
```

- [ ] **Step 3: Build**

Run:
```bash
cd docker && docker build -f lab.dockerfile -t hcie/lab:wip . 2>&1 | tail -20
```
Expected: succeeds. Allow ~25 minutes.

- [ ] **Step 4: Verify torch, torch_npu and numpy**

Run:
```bash
docker run --rm hcie/lab:wip conda run -n pytorch python -c \
"import torch, numpy; print('torch', torch.__version__, '| numpy', numpy.__version__)"
docker run --rm hcie/lab:wip conda run -n pytorch pip show torch_npu | grep -E "^(Name|Version)"
```
Expected: `torch 2.2.0 | numpy 1.26.4`, then `torch-npu` / `2.2.0.post1`.

**`import torch_npu` is deliberately NOT run here.** It dlopens
`libascend_hal.so`, which ships with the NPU *driver*, not the toolkit, and is
host-mounted at runtime — so the import can only succeed on the Atlas machine.
On the build host `pip show` is the correct check that the wheel installed.
Both the import and `torch_npu.npu.is_available()` belong to the deferred
NPU-host checks in Task 7.

- [ ] **Step 5: Verify MindFormers imports in the mindspore env**

Run:
```bash
docker run --rm hcie/lab:wip conda run -n mindspore python -c \
"import mindformers; print('mindformers', mindformers.__version__)"
```
Expected: a version string, no traceback.

- [ ] **Step 6: Re-verify the mindspore env still has numpy 1.26.4**

The MindFormers build installs `requirements.txt`, which is exactly the thing known to drag numpy 2.x back in.

Run:
```bash
docker run --rm hcie/lab:wip conda run -n mindspore python -c \
"import numpy; print(numpy.__version__)"
```
Expected: `1.26.4`

- [ ] **Step 7: Commit**

```bash
git add docker/lab.dockerfile
git commit -m "feat: bake the pytorch env and MindFormers into the lab image"
```

---

### Task 5: JupyterLab, kernels, entrypoint

Completes the image.

**Files:**
- Modify: `docker/lab.dockerfile` (append)

**Interfaces:**
- Consumes: both envs from Tasks 3–4; `entrypoint.sh` and `start-jupyter.sh` from Task 1.
- Produces: the finished `hcie/lab:8.0rc1-910b` — JupyterLab in base env, kernels `mindspore` and `pytorch`, ENTRYPOINT set, `CMD ["/bin/bash"]`.

- [ ] **Step 1: Append the Jupyter, kernel and entrypoint layers**

```dockerfile
# ---- JupyterLab -----------------------------------------------------------
# Installed ONLY in the base env. Putting it in the lab envs would pull a
# dependency tree that reintroduces numpy 2.x and breaks both frameworks.
RUN "${CONDA_DIR}/bin/pip" install --no-cache-dir --index-url "${PIP_INDEX}" \
        jupyterlab notebook

# Each lab env gets ipykernel only, and registers itself as a named kernel.
RUN . "${CONDA_DIR}/etc/profile.d/conda.sh" \
    && for env in mindspore pytorch; do \
         conda activate "$env" \
         && pip install --no-cache-dir ipykernel \
         && python -m ipykernel install --prefix="${CONDA_DIR}" \
              --name "$env" --display-name "Python 3.9 ($env)" \
         && pip install --no-cache-dir "numpy==${NUMPY_PIN}" \
         && conda deactivate; \
       done \
    && conda clean -afy

COPY entrypoint.sh start-jupyter.sh /opt/bin/
RUN chmod +x /opt/bin/entrypoint.sh /opt/bin/start-jupyter.sh

EXPOSE 8888
WORKDIR /workspace

LABEL com.hcie.image=lab \
      com.hcie.cann.version=8.0.RC1 \
      com.hcie.envs=mindspore,pytorch

ENTRYPOINT ["/opt/bin/entrypoint.sh"]
CMD ["/bin/bash"]
```

- [ ] **Step 2: Build and tag properly**

Run:
```bash
cd docker && docker build -f lab.dockerfile -t hcie/lab:8.0rc1-910b . 2>&1 | tail -20
```
Expected: succeeds.

- [ ] **Step 3: Verify both kernels are registered**

Run:
```bash
docker run --rm hcie/lab:8.0rc1-910b jupyter kernelspec list
```
Expected: both `mindspore` and `pytorch` listed under `/opt/miniforge3/share/jupyter/kernels`.

- [ ] **Step 4: Verify the entrypoint creates the MindFormers symlink**

Run:
```bash
docker run --rm hcie/lab:8.0rc1-910b bash -lc 'readlink -f /workspace/code/mindformers'
```
Expected: `/opt/mindformers`

- [ ] **Step 5: Verify a real workspace clone wins over the baked copy**

The symlink must not clobber a user's own checkout.

Run:
```bash
TMP=$(mktemp -d)
mkdir -p "$TMP/code/mindformers" && touch "$TMP/code/mindformers/USER_COPY"
docker run --rm -v "$TMP:/workspace" hcie/lab:8.0rc1-910b \
  bash -lc 'ls /workspace/code/mindformers'
rm -rf "$TMP"
```
Expected: `USER_COPY` — proving the entrypoint left the existing directory alone.

- [ ] **Step 6: Verify JupyterLab starts and reports a token**

Run:
```bash
docker run --rm -d --name jl-test hcie/lab:8.0rc1-910b sleep 300
docker exec jl-test bash -lc 'bash /opt/bin/start-jupyter.sh'
docker rm -f jl-test
```
Expected: a `http://...:8888/lab?token=...` line. Confirms both the server and token auth.

- [ ] **Step 7: Commit**

```bash
git add docker/lab.dockerfile
git commit -m "feat: JupyterLab, kernels and entrypoint for the lab image"
```

---

### Task 6: Update scripts and README

Points the existing tooling at the new image and removes every reference to the deleted `02-conda-envs.sh`.

**Files:**
- Modify: `scripts/01-run-container.sh:6`, and the `docker run` block
- Modify: `scripts/04-verify.sh:38`
- Modify: `README.md` (lines ~47-90, ~160-165, ~205-220)

**Interfaces:**
- Consumes: `hcie/lab:8.0rc1-910b` from Task 5.
- Produces: no code interface — this is the documentation and wiring pass.

- [ ] **Step 1: Point `01-run-container.sh` at the new image**

In `scripts/01-run-container.sh` line 6, change:
```bash
IMAGE="${HCIE_IMAGE:-hcie-cann:8.0.RC1}"
```
to:
```bash
IMAGE="${HCIE_IMAGE:-hcie/lab:8.0rc1-910b}"
```

- [ ] **Step 2: Fix the build hint in the same file**

Lines 18-20 tell the user to build the old image. Change the hint to:
```bash
    echo "image '$IMAGE' not found — build it first:" >&2
    echo "  docker build -f docker/cann.dockerfile -t hcie/cann:8.0rc1-910b docker/" >&2
    echo "  docker build -f docker/lab.dockerfile  -t $IMAGE docker/" >&2
```

- [ ] **Step 3: Add the port mapping and update the closing hint**

In the `docker run` block add `-p 8888:8888` (a no-op under `--network host`, but correct if that is ever dropped). Then replace the trailing heredoc's `02-conda-envs.sh` line so it reads:
```bash
cat <<EOF

Container running.

  docker exec -it $NAME bash
  bash /opt/bin/start-jupyter.sh      # JupyterLab on :8888
  bash /workspace/scripts/04-verify.sh
EOF
```

- [ ] **Step 4: Fix the stale message in `04-verify.sh`**

Line 38 currently reads:
```bash
    fail "miniforge missing — run 02-conda-envs.sh"
```
Change to:
```bash
    fail "miniforge missing — wrong image? expected hcie/lab:8.0rc1-910b"
```

- [ ] **Step 5: Verify both scripts still parse**

Run:
```bash
bash -n scripts/01-run-container.sh && bash -n scripts/04-verify.sh && echo "syntax ok"
```
Expected: `syntax ok`

- [ ] **Step 6: Confirm no script still references the deleted file**

Run: `grep -rn "02-conda-envs" scripts/ README.md || echo "clean"`
Expected: only `README.md` hits remain at this point (fixed in the next step), or `clean`.

- [ ] **Step 7: Update the README**

Make these edits:
- **Step 2 build section (~line 47-65):** document both builds — `cann.dockerfile` → `hcie/cann:8.0rc1-910b`, then `lab.dockerfile` → `hcie/lab:8.0rc1-910b`. Replace the `-t hcie-cann:8.0.RC1` tag.
- **~line 83:** delete the `bash /workspace/scripts/02-conda-envs.sh` step. Replace with a note that the envs are already in the image, and add `bash /opt/bin/start-jupyter.sh` for JupyterLab on 8888 with token auth.
- **~line 162:** the numpy-pin paragraph must no longer credit `02-conda-envs.sh`. Reword to: the image pins `numpy==1.26.4` in both envs, and lab `requirements.txt` files will undo it — re-pin after any lab install.
- **~line 214 (repo tree):** remove the `02-conda-envs.sh` line; add `docker/lab.dockerfile`, `docker/entrypoint.sh`, `docker/start-jupyter.sh`, `docker/aria2c.conf`.
- **Table at ~line 23:** add a row noting conda envs + JupyterLab now come from the image.
- Note that lab 07 (LLaVA) is not supported by this image.

- [ ] **Step 8: Verify the README is clean**

Run: `grep -rn "02-conda-envs\|hcie-cann:8.0.RC1" scripts/ README.md || echo "clean"`
Expected: `clean`

- [ ] **Step 9: Commit**

```bash
git add scripts/01-run-container.sh scripts/04-verify.sh README.md
git commit -m "docs: point scripts and README at the lab image"
```

---

### Task 7: End-to-end verification

Confirms the image satisfies the spec, and records what can only be checked on the Atlas machine.

**Files:**
- Create: `docs/superpowers/plans/2026-07-28-hcie-lab-image-verification.md`

**Interfaces:**
- Consumes: everything above.
- Produces: a verification log committed alongside the plan.

- [ ] **Step 1: Run the full build-host check**

Run:
```bash
docker run --rm hcie/lab:8.0rc1-910b bash -lc '
set -e
echo "== envs =="        && conda env list
echo "== mindspore ==" && conda run -n mindspore python -c "import mindspore,numpy;print(mindspore.__version__, numpy.__version__)"
echo "== pytorch ==" && conda run -n pytorch python -c "import torch,numpy;print(torch.__version__, numpy.__version__)"
echo "== torch_npu wheel ==" && conda run -n pytorch pip show torch_npu | grep -E "^(Name|Version)"
echo "== mindformers ==" && conda run -n mindspore python -c "import mindformers;print(mindformers.__version__)"
echo "== kernels =="   && jupyter kernelspec list
echo "== tools =="     && git-lfs --version && aria2c --version | head -1
echo "== aria2 conf ==" && grep -c . /etc/aria2/aria2c.conf
echo "== mindformers link ==" && readlink -f /workspace/code/mindformers
'
```
Expected: MindSpore 2.3.0rc2, torch 2.2.0, **numpy 1.26.4 in both**, both kernels, symlink to `/opt/mindformers`.

- [ ] **Step 2: Run `04-verify.sh` inside the image**

Run:
```bash
docker run --rm -v "$PWD/scripts:/workspace/scripts:ro" hcie/lab:8.0rc1-910b \
  bash -lc 'bash /workspace/scripts/04-verify.sh' || true
```
Expected: NPU and lab-asset checks fail or warn (no NPU on this Mac, no models downloaded); **conda, frameworks, numpy and tools checks all pass**. Any failure in those four sections is a real defect.

- [ ] **Step 3: Record the image size**

Run: `docker images hcie/lab:8.0rc1-910b --format '{{.Size}}'`
Expected: roughly 25-30 GB per the spec. Note the actual figure.

- [ ] **Step 4: Write the verification log**

Create `docs/superpowers/plans/2026-07-28-hcie-lab-image-verification.md` recording: the exact command output from Steps 1-3, the actual image size, and a **Deferred to the Atlas 800T A2** section listing the checks that cannot pass on the build host:

```
npu-smi info                                        # needs the NPU driver
mindspore.run_check() with device_target='Ascend'   # needs NPU
torch_npu.npu.is_available()  -> True               # needs NPU
atc --help                                          # needs libascend_hal.so from the host-mounted driver
```

State plainly that `libascend_hal.so` ships with the driver, not the toolkit, so its absence here is expected and not a defect.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/plans/2026-07-28-hcie-lab-image-verification.md
git commit -m "docs: build-host verification log for the lab image"
```

---

## Self-Review

**Spec coverage:**

| Spec requirement | Task |
|---|---|
| Base on `hcie/cann:8.0rc1-910b`, unchanged | 2 (Global Constraints) |
| Miniforge at `/opt/miniforge3` | 2 |
| `mindspore` env, py3.9, MS 2.3.0rc2, te/hccl | 3 |
| `pytorch` env, py3.9, torch 2.2.0 + torch_npu | 4 |
| numpy 1.26.4 pinned last in every env | 3, 4, 5 (+ re-checked in 4.6) |
| MindFormers r1.1.0 at `/opt`, symlinked at runtime | 1, 4 |
| Real workspace clone wins over baked copy | 1, 5.5 |
| JupyterLab in base env only, 2 kernels | 5 |
| Token auth on 8888 | 1, 5.6 |
| `CMD ["/bin/bash"]` preserved | 5 |
| aria2c.conf baked in | 1, 2 |
| git-lfs 3.5.1, aria2, unzip | 2 |
| One `RUN` per env (fail loudly) | 3, 4 |
| `01-run-container.sh` image tag + 8888 | 6 |
| `04-verify.sh:38` message | 6 |
| llava / APEX excluded | Global Constraints |
| Build-host vs NPU verification split | 7 |

No gaps.

**Placeholder scan:** No TBDs. Every code step carries literal content; every README edit in Task 6 names the target lines and the replacement wording.

**Type consistency:** `$CONDA_DIR` (`/opt/miniforge3`), `$NUMPY_PIN` (`1.26.4`), `$PIP_INDEX` and `$ASCEND_TOOLKIT_HOME` are used identically across Tasks 2-5. Env names `mindspore` / `pytorch` match between creation (3, 4), kernel registration (5), `04-verify.sh` (existing), and verification (7). Paths `/opt/mindformers`, `/opt/bin/entrypoint.sh`, `/opt/bin/start-jupyter.sh` agree between Task 1's scripts and Task 5's `COPY`.

**One known risk:** Task 4 Step 6 exists because MindFormers' `build.sh` installs `requirements.txt`, the exact mechanism that reintroduces numpy 2.x. If that check fails, add a final `pip install "numpy==${NUMPY_PIN}"` to the MindFormers layer — it is already there, but verify it ran after the build rather than before.

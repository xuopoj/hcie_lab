# HCIE-AI Solution Architect V1.0 — Lab Environment Setup

Reproduces the lab environment from *HCIE-AI Solution Architect V1.0 实验手册* on a new
Atlas 800T A2 machine.

**Key difference from the official manual:** CANN is baked into a Docker image
(`docker/cann.dockerfile`), so you skip 实验三 (NPU 驱动及 CANN 软件安装) entirely except
for the host driver. Everything else — conda envs, frameworks, models, datasets — runs
*inside* the container.

---

## What the host must provide

The container ships CANN Toolkit + kernels. It does **not** ship the driver — that is
kernel-coupled and must live on the host.

| Component | Where | Notes |
|---|---|---|
| NPU driver + firmware | **Host** | `Ascend-hdk-910b-npu-driver_*.run`, must match CANN 8.0.RC1 (driver 24.1.1) |
| Docker | **Host** | 24.0.9+ |
| Ascend Docker Runtime | **Host** | Injects `/dev/davinci*` + driver libs into the container |
| CANN Toolkit + kernels | **Image** | Already in `cann.dockerfile` |
| conda envs + frameworks + JupyterLab | **Image** | Baked into `lab.dockerfile` — ready at container start |
| Models / datasets | **Container** | Via `03-download.sh` into the mounted `workspace/` |

Verify the host driver before anything else:

```bash
npu-smi info          # must list 8 healthy devices
cat /usr/local/Ascend/driver/version.info
```

If `npu-smi` is missing or reports errors, stop — no container work will succeed.

---

## Step 1 — Host prerequisites

```bash
sudo bash scripts/00-host-prereqs.sh
```

Installs Docker + Ascend Docker Runtime and restarts the Docker daemon. Skips anything
already present. Does **not** touch the NPU driver — install that manually from Huawei
support, since the version must be matched to your firmware.

## Step 2 — Build the images

Place the CANN `.run` installers in `docker/packages/8.0.RC1/`:

```
docker/packages/8.0.RC1/
├── Ascend-cann-toolkit_8.0.RC1_linux-aarch64.run
└── Ascend-cann-kernels-910b_8.0.RC1_linux.run
```

Two images, built in order. The first carries CANN; the second adds everything else.

```bash
# 1. CANN toolkit + 910b kernels  (~10 GB)
DOCKER_BUILDKIT=1 docker build \
  -f docker/cann.dockerfile \
  -t hcie/cann:8.0rc1-910b \
  docker/

# 2. conda envs + MindFormers + JupyterLab  (~14 GB total, 40-70 min)
docker build \
  -f docker/lab.dockerfile \
  -t hcie/lab:8.0rc1-910b \
  docker/
```

BuildKit is required for the first — it bind-mounts the installers so the multi-GB `.run`
files never land in an image layer.

The second image bakes in Miniforge, both conda environments, MindFormers r1.1.0 and
JupyterLab. It is slow to build once so that the container needs no setup and no network
at lab time.

## Step 3 — Start the container

```bash
bash scripts/01-run-container.sh
```

Mounts all 8 NPUs, the driver, and a persistent `workspace/` for models and datasets.
Model weights total **~150 GB** if you run every lab — keep `workspace/` on a large disk.
Override with `HCIE_WORKSPACE=/data/hcie bash scripts/01-run-container.sh`.

Re-running attaches to the existing container instead of creating a duplicate.

## Step 4 — (nothing to do)

The conda environments ship inside the image, so there is no setup step. Confirm with:

```bash
docker exec -it hcie-lab bash
bash /workspace/scripts/04-verify.sh
```

See "Environment layout" below for why there are two environments.

For a notebook UI:

```bash
bash /opt/bin/start-jupyter.sh      # JupyterLab on :8888, prints its token URL
```

Both environments appear as kernels — "Python 3.9 (mindspore)" and "Python 3.9 (pytorch)".
JupyterLab itself lives in the Miniforge base env, deliberately kept out of the lab envs
so its dependencies cannot disturb their pinned numpy.

## Step 5 — Download models and datasets

```bash
bash /workspace/scripts/03-download.sh --lab all     # everything, ~150 GB
bash /workspace/scripts/03-download.sh --lab lab01   # just what one lab needs
bash /workspace/scripts/03-download.sh --list        # show sizes without downloading
```

Resumable and idempotent — safe to re-run after an interrupted download.

---

## Environment layout

The manual has you build one env and repeatedly reinstall packages as labs change. That
breaks down because the labs have genuinely conflicting pins:

- MindSpore 2.3.0rc2 requires `numpy==1.26.4`
- LLaVA requires `numpy==1.21.2`
- MindFormers labs want `transformers==4.39.3`; ChatGLM2 migration wants whatever its
  `requirements.txt` pins

So this setup uses two base envs plus one throwaway:

| Env | Python | Stack | Labs |
|---|---|---|---|
| `mindspore` | 3.9 | MindSpore 2.3.0rc2 + MindFormers r1.1.0 | 数据工程, MindFormers 推理, Baichuan2 微调/推理, InternLM, ChatGLM3, Open-Sora |
| `pytorch` | 3.9 | PyTorch 2.2.0 + torch_npu 2.2.0.post1 + DeepSpeed | ChatGLM2 迁移, BEiT V2, ViT |
| `llava` | 3.10 | **Not in the image.** Created on demand, then `pip install -e .` | LLaVA only (numpy 1.21.2 conflict) |

`mindspore` and `pytorch` are baked into `lab.dockerfile` and ready at container start.

The `llava` env is **not** part of the image: lab 07 needs PyTorch 2.1 and numpy 1.21.2,
which conflict with the 2.2.0 / 1.26.4 pins every other lab needs. `03-download.sh --lab
lab07` still creates a bare env on demand, which you then finish by hand.

**Ascend APEX is not installed.** If a mixed-precision lab needs it, build it from
`https://gitee.com/ascend/apex` inside the `pytorch` env (20–40 min).

**Which env for which lab:**

```bash
mamba activate mindspore   # 数据工程 / MindFormers / Baichuan2 / InternLM / ChatGLM3
mamba activate pytorch     # ChatGLM2 迁移 / BEiT / ViT
mamba activate llava       # LLaVA
```

---

## Lab → asset map

| Lab | Chapter | Env | Assets |
|---|---|---|---|
| 数据工程 | 第3章 | mindspore | `mindformers.zip`, `belle_chat_ramdon_10k.json`, Baichuan2-7B-Base `tokenizer.model` |
| ChatGLM2-6B 迁移 | 第9章 | pytorch | ModelZoo-PyTorch, `AdvertiseGen.zip`, `THUDM/chatglm2-6b` |
| MindFormers 推理 | 第11章 | mindspore | `mindformers.zip`, `baichuan-inc/Baichuan2-7B-Chat` |
| 大模型微调 | 第12章 | mindspore | `mindformers.zip`, `baichuan-inc/Baichuan2-7B-Base` |
| 大模型推理 | 第14章 | mindspore | `mindformers.zip`, `baichuan-inc/Baichuan2-7B-Chat` |
| 大语言模型综合 | — | mindspore | `internlm.ckpt`, `internlm-chat.ckpt`, `tokenizer.model`, `glm3_6b.ckpt`, ToolAlpaca |
| 多模态 (1) LLaVA | — | llava | `LLaVA.zip`, vicuna-7b-v1.5, clip-vit-large-patch14-336, llava-v1.5-7b + pretrain projector |
| 多模态 (2) Open-Sora | — | mindspore | `mindone.zip`, `DeepFloyd/t5-v1_1-xxl`, `Open-Sora-Plan-v1.0.0`, ffmpeg 4.0.1, decord |
| 视觉 (1) BEiT V2 | — | pytorch | `HCIE-Experiment_Manual-Migration_Vision.zip`, COCO2017 (~25 GB) |
| 视觉 (2) ViT | — | pytorch | same zip, bundled `vit_imagenet_dataset.zip` |

Note the MindFormers labs reuse the *same* `mindformers.zip` from Huawei's OBS — it is
downloaded once into `workspace/code/` and shared.

---

## Gotchas

**numpy gets silently upgraded.** Almost every `pip install` in the manual pulls numpy
2.x back in as a transitive dep, which breaks MindSpore and torch_npu. After installing
*any* lab's `requirements.txt`, re-pin:

```bash
pip install "numpy==1.26.4"
python -c "import numpy; print(numpy.__version__)"
```

The image ships `numpy==1.26.4` in both environments, but lab `requirements.txt` files
will undo it — re-pin after any lab install.

**ChatGLM2 `modeling_chatglm.py` must not be overwritten.** The Ascend-migrated copy in
`model/` is the adapted one. When you move the HF download into place, delete the HF
copy of that file first — otherwise you silently lose the NPU adaptation and the run
falls back to CPU paths.

**`aclInit 500000 / adx -1`.** Recurring NPU init failure. Retry first; only then
`pkill` stale processes and clear stale IPC segments with `ipcrm`.

**MindSpore verify needs a real NPU.** `mindspore.run_check()` with
`device_target='Ascend'` will fail in a container without `/dev/davinci*` mapped. That
is a mount problem, not an install problem — check `01-run-container.sh` ran with all
device flags.

**hfd.sh + aria2c.** Direct `huggingface.co` is typically unreachable; the scripts set
`HF_ENDPOINT=https://hf-mirror.com`. If a download stalls, kill it and re-run — aria2c
resumes.

**Two URLs in the manual are wrong.** The belle dataset path is `fine-tune/data/`, not
`finetune/data/` — the scripts use the corrected one. And the Ascend Docker Runtime has
no scriptable download URL (Gitee blocks it), so `00-host-prereqs.sh` asks you to place
the `.run` file manually. You can also skip the runtime entirely: `01-run-container.sh`
passes `/dev/davinci*` explicitly, so the labs work without it.

**APEX is not in the image.** It compiles from source and takes 20-40 min on Atlas
hardware, so it was left out rather than added to every build. It only matters for the
PyTorch mixed-precision labs; build it by hand in the `pytorch` env if one needs it.

---

## Verification

```bash
bash scripts/04-verify.sh
```

Checks NPU visibility, both conda envs, framework imports, and reports which lab assets
are present. Run it after setup and any time a lab misbehaves.

---

## Layout

```
hcie_lab/
├── README.md
├── docker/
│   ├── cann.dockerfile            # CANN toolkit + 910b kernels
│   ├── lab.dockerfile             # conda envs + MindFormers + JupyterLab
│   ├── entrypoint.sh              # ascend env + mindformers symlink
│   ├── start-jupyter.sh           # JupyterLab on :8888
│   ├── aria2c.conf                # resumable multi-connection downloads
│   └── packages/8.0.RC1/          # CANN .run installers (not in git)
├── scripts/
│   ├── 00-host-prereqs.sh         # host: docker + ascend runtime
│   ├── 01-run-container.sh        # host: launch container with NPUs
│   ├── 03-download.sh             # container: models + datasets
│   └── 04-verify.sh               # container: health check
└── workspace/                     # persistent, mounted at /workspace (not in git)
    ├── code/
    ├── models/
    └── datasets/
```

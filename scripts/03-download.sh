#!/usr/bin/env bash
# Container: download models, datasets and code for the HCIE labs.
# Idempotent and resumable — re-run freely after an interrupted download.
set -euo pipefail

WS="${HCIE_WS:-/workspace}"
CODE="$WS/code"; MODELS="$WS/models"; DATA="$WS/datasets"
export HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
OBS="https://certification-data.obs.cn-north-4.myhuaweicloud.com/CHS/HCIE-AI%20Solution%20Architect"
MODELZOO="https://ascend-repo-modelzoo.obs.cn-east-2.myhuaweicloud.com"

LABS="lab01 lab02 lab03 lab04 lab05 lab06 lab07 lab08 lab09 lab10"

describe() {
    case "$1" in
      lab01) echo "数据工程 (mindspore)              ~20 MB   mindformers.zip, belle 10k, Baichuan2 tokenizer" ;;
      lab02) echo "ChatGLM2-6B 迁移 (pytorch)        ~13 GB   ModelZoo-PyTorch, AdvertiseGen, chatglm2-6b" ;;
      lab03) echo "MindFormers 推理 (mindspore)      ~15 GB   mindformers.zip, Baichuan2-7B-Chat" ;;
      lab04) echo "大模型微调 (mindspore)            ~15 GB   mindformers.zip, Baichuan2-7B-Base" ;;
      lab05) echo "大模型推理 (mindspore)            shared   reuses lab03 assets" ;;
      lab06) echo "大语言模型综合 (mindspore)        ~40 GB   InternLM ckpts, glm3_6b.ckpt, ToolAlpaca" ;;
      lab07) echo "多模态 LLaVA (llava env)          ~30 GB   vicuna-7b, clip-336, llava-v1.5-7b" ;;
      lab08) echo "多模态 Open-Sora (mindspore)      ~25 GB   mindone, t5-v1_1-xxl, Open-Sora-Plan-v1.0.0" ;;
      lab09) echo "视觉 BEiT V2 (pytorch)            ~27 GB   vision zip, COCO2017" ;;
      lab10) echo "视觉 ViT (pytorch)                ~2 GB    vision zip (dataset bundled)" ;;
    esac
}

usage() {
    cat <<EOF
usage: $0 --lab <name|all> [--lab <name>...]
       $0 --list

Labs:
EOF
    for l in $LABS; do printf "  %-7s %s\n" "$l" "$(describe "$l")"; done
    echo
    echo "Downloads land in $WS/{code,models,datasets}. Total for 'all': ~150 GB."
}

# --- helpers ---------------------------------------------------------------

log() { echo "  -> $*"; }

# Fetch a URL to a target path; skip if already there. -C - resumes partial files.
fetch() {
    local url="$1" dest="$2"
    if [[ -s "$dest" ]]; then log "have $(basename "$dest")"; return; fi
    log "fetch $(basename "$dest")"
    mkdir -p "$(dirname "$dest")"
    curl -fL -C - --retry 3 --retry-delay 5 -o "$dest" "$url"
}

# Fetch + unzip an OBS archive into a directory, keyed on a marker path.
fetch_zip() {
    local url="$1" dest_dir="$2" marker="$3"
    if [[ -e "$dest_dir/$marker" ]]; then log "have $marker"; return; fi
    local tmp="/tmp/$(basename "${url%%\?*}")"
    log "fetch+unzip $(basename "${url%%\?*}")"
    [[ -s "$tmp" ]] || curl -fL -C - --retry 3 -o "$tmp" "$url"
    mkdir -p "$dest_dir"
    unzip -q -o "$tmp" -d "$dest_dir"
    rm -f "$tmp"
}

clone() {
    local url="$1" dest="$2" branch="${3:-}"
    if [[ -d "$dest/.git" ]]; then log "have $(basename "$dest")"; return; fi
    log "clone $(basename "$dest")"
    if [[ -n "$branch" ]]; then git clone -b "$branch" "$url" "$dest"
    else git clone "$url" "$dest"; fi
}

# Download a HF repo via hfd.sh + aria2c. Completion is marked with a stamp file
# because hfd has no reliable "already complete" check of its own.
HFD="/tmp/hfd.sh"
hf_download() {
    local repo="$1" dest="$MODELS/$(basename "$1")"
    if [[ -f "$dest/.hcie-complete" ]]; then log "have $repo"; return; fi
    [[ -x "$HFD" ]] || { curl -fL -o "$HFD" "$HF_ENDPOINT/hfd/hfd.sh"; chmod +x "$HFD"; }
    log "hf $repo -> $dest"
    mkdir -p "$dest"
    # hfd deletes any needed file that has no .aria2 control file, on the theory
    # that -c cannot fix it ("drop a wrong-size copy", hfd.sh ~line 275). But
    # aria2c REMOVES the control file when a file completes — so on the next
    # pass every finished shard looks unfixable and is deleted. On a 12.5 GB
    # repo that never finishes in one pass, each retry destroys the previous
    # pass's completed files: lab02's shards went 3.7 -> 7.5 -> 10 -> 6.0 -> 4.2 GB
    # and two completed 1.9 GB shards came back as ~36 MB.
    #
    # DO NOT try to work around this by parking completed files elsewhere before
    # each pass. That was tried and made things worse: a partial file also has
    # no .aria2 companion between aria2c runs, so partials get parked too, hfd
    # restarts them from zero, and the restore overwrites a 1.7 GB shard with a
    # 2 MB one. The right fix is to stop using hfd for HF repos — see
    # docs/superpowers/plans/2026-08-02-download-status.md.
    local tries="${HCIE_HF_TRIES:-8}" i delay="${HCIE_HF_DELAY:-30}"
    for (( i = 1; i <= tries; i++ )); do
        (cd "$MODELS" && "$HFD" "$repo" --tool aria2c -x "${HCIE_HF_CONN:-1}" --local-dir "$dest")
        local rc=$?

        # Trust the absence of .aria2 files over hfd's exit code alone.
        if [[ $rc -eq 0 ]] && ! find "$dest" -maxdepth 1 -name '*.aria2' | grep -q .; then
            touch "$dest/.hcie-complete"
            return 0
        fi
        if [[ $i -lt $tries ]]; then
            log "attempt $i/$tries incomplete — retrying in ${delay}s"
            sleep "$delay"
            delay=$(( delay * 2 )); [[ $delay -gt 300 ]] && delay=300
        fi
    done
    log "FAILED $repo after $tries attempts — not stamping; re-run to resume"
    return 1
}

# The MindFormers labs all share this one archive.
# entrypoint.sh symlinks the baked /opt/mindformers into $CODE. Writing lab assets
# through that symlink puts them in the container layer, not the workspace mount,
# so they vanish on restart. Replace it with a real copy first.
mindformers_zip() {
    if [[ -L "$CODE/mindformers" ]]; then
        log "materialising mindformers from $(readlink "$CODE/mindformers")"
        mkdir -p "$CODE/mindformers.tmp"
        cp -a "$(readlink -f "$CODE/mindformers")/." "$CODE/mindformers.tmp/"
        rm -f "$CODE/mindformers"
        mv "$CODE/mindformers.tmp" "$CODE/mindformers"
    fi
    fetch_zip "$OBS/mindformers.zip" "$CODE" "mindformers"
}

# --- labs ------------------------------------------------------------------

lab01() {
    mindformers_zip
    local d="$CODE/mindformers/research/baichuan2"
    # Manual says finetune/data/ but the repo path is fine-tune/data/ (hyphenated).
    fetch "https://raw.githubusercontent.com/baichuan-inc/Baichuan2/main/fine-tune/data/belle_chat_ramdon_10k.json" \
          "$d/belle_chat_ramdon_10k.json"
    # tokenizer.model only — the full 7B weights are not needed for data conversion.
    fetch "$HF_ENDPOINT/baichuan-inc/Baichuan2-7B-Base/resolve/main/tokenizer.model" \
          "$d/tokenizer.model"
    cat <<EOF

  lab01 ready. Convert the dataset with:
    mamba activate mindspore && cd $d
    python belle_preprocess.py --input_glob belle_chat_ramdon_10k.json \\
      --model_file tokenizer.model \\
      --output_file belle_chat_ramdon_10k_4096.mindrecord --seq_length 4096
EOF
}

lab02() {
    clone "https://gitee.com/ascend/ModelZoo-PyTorch.git" "$CODE/ModelZoo-PyTorch"
    local d="$CODE/ChatGLM2"
    mkdir -p "$d"
    [[ -d "$d/ChatGLM2-6B" ]] || \
        cp -r "$CODE/ModelZoo-PyTorch/PyTorch/built-in/foundation/ChatGLM2-6B" "$d/"
    fetch_zip "$OBS/AdvertiseGen.zip" "$d/ChatGLM2-6B" "AdvertiseGen"
    hf_download "THUDM/chatglm2-6b"
    cat <<'EOF'

  WARNING — lab02 manual step, do not skip:
  model/modeling_chatglm.py in the migrated code is the NPU-adapted version. Before
  moving the HF weights into model/, DELETE the HF copy of modeling_chatglm.py.
  Overwriting it silently drops the NPU adaptation.
EOF
}

lab03() { mindformers_zip; hf_download "baichuan-inc/Baichuan2-7B-Chat"; }
lab04() { mindformers_zip; hf_download "baichuan-inc/Baichuan2-7B-Base"; }
lab05() { echo "  lab05 shares lab03 assets"; lab03; }

lab06() {
    mindformers_zip
    fetch "$MODELZOO/MindFormers/internlm/internlm.ckpt"      "$MODELS/InternLM-7B/internlm.ckpt"
    fetch "$MODELZOO/MindFormers/internlm/internlm-chat.ckpt" "$MODELS/InternLM-7B/internlm-chat.ckpt"
    fetch "$MODELZOO/MindFormers/internlm/tokenizer.model"    "$MODELS/InternLM-7B/tokenizer.model"
    fetch "$MODELZOO/XFormer_for_mindspore/glm3/glm3_6b.ckpt"    "$MODELS/glm3-6b/glm3_6b.ckpt"
    fetch "$MODELZOO/XFormer_for_mindspore/glm3/tokenizer.model" "$MODELS/glm3-6b/tokenizer.model"
    clone "https://github.com/tangqiaoyu/ToolAlpaca" "$CODE/ToolAlpaca"
}

lab07() {
    fetch_zip "$OBS/LLaVA.zip" "$CODE" "LLaVA"
    hf_download "lmsys/vicuna-7b-v1.5"
    hf_download "openai/clip-vit-large-patch14-336"
    hf_download "liuhaotian/llava-v1.5-mlp2x-336px-pretrain-vicuna-7b-v1.5"
    hf_download "liuhaotian/llava-v1.5-7b"

    # LLaVA pins numpy 1.21.2, which is incompatible with the mindspore/pytorch envs.
    if command -v mamba &>/dev/null && ! conda env list | awk '{print $1}' | grep -qx llava; then
        log "creating dedicated 'llava' env (numpy 1.21.2 conflict)"
        mamba create -n llava python=3.10 -y
        cat <<'EOF'

  Finish the llava env manually:
    mamba activate llava && cd /workspace/code/LLaVA
    pip install -e .
    pip install matplotlib pandas numpy==1.21.2
EOF
    fi
}

lab08() {
    fetch_zip "$OBS/mindone.zip" "$CODE" "mindone"
    hf_download "DeepFloyd/t5-v1_1-xxl"
    hf_download "LanguageBind/Open-Sora-Plan-v1.0.0"
    cat <<'EOF'

  lab08 also needs ffmpeg 4.0.1 + decord built from source:
    wget https://ffmpeg.org/releases/ffmpeg-4.0.1.tar.bz2 --no-check-certificate
    git clone --recursive https://github.com/dmlc/decord
  See the manual — these are long source builds.
EOF
}

lab09() {
    fetch_zip "$OBS/HCIE-Experiment_Manual-Migration_Vision.zip" "$CODE" \
              "HCIE-Experiment_Manual-Migration_Vision"
    local d="$DATA/coco2017"
    mkdir -p "$d"
    for part in train2017 val2017 test2017; do
        if [[ -d "$d/$part" ]]; then log "have $part"; continue; fi
        fetch "http://images.cocodataset.org/zips/${part}.zip" "$d/${part}.zip"
        log "unzip $part"; unzip -q -o "$d/${part}.zip" -d "$d" && rm -f "$d/${part}.zip"
    done
    if [[ ! -d "$d/annotations" ]]; then
        fetch "http://images.cocodataset.org/annotations/annotations_trainval2017.zip" \
              "$d/annotations.zip"
        unzip -q -o "$d/annotations.zip" -d "$d" && rm -f "$d/annotations.zip"
    fi
    echo "  NOTE: move vqkd_encoder_base_decoder_3x768x12_clip-*.pth into BEiT2_for_PyTorch/tokenizer_model/"
}

lab10() {
    fetch_zip "$OBS/HCIE-Experiment_Manual-Migration_Vision.zip" "$CODE" \
              "HCIE-Experiment_Manual-Migration_Vision"
    echo "  vit_imagenet_dataset.zip is bundled in the zip; unzip it inside vit_base_patch32_224/"
}

# --- main ------------------------------------------------------------------

[[ $# -gt 0 ]] || { usage; exit 1; }

SELECTED=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --list) usage; exit 0 ;;
        --lab) [[ "$2" == "all" ]] && SELECTED=($LABS) || SELECTED+=("$2"); shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown arg: $1" >&2; usage; exit 1 ;;
    esac
done

for lab in "${SELECTED[@]}"; do
    declare -F "$lab" >/dev/null || { echo "unknown lab: $lab" >&2; exit 1; }
done

mkdir -p "$CODE" "$MODELS" "$DATA"
command -v aria2c &>/dev/null || echo "WARNING: aria2c missing — wrong image? expected hcie/lab:8.0rc1-910b"

for lab in "${SELECTED[@]}"; do
    echo "==> $lab: $(describe "$lab")"
    "$lab"
done

echo
echo "Done. Disk used: $(du -sh "$WS" 2>/dev/null | cut -f1)"

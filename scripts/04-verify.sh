#!/usr/bin/env bash
# Container: health check for NPUs, CANN, conda envs, frameworks and lab assets.
# Exits non-zero if anything essential is broken.
set -uo pipefail

WS="${HCIE_WS:-/workspace}"
CONDA_DIR="${CONDA_DIR:-/opt/miniforge3}"
FAIL=0

pass() { printf "  \033[32mok\033[0m   %s\n" "$*"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$*"; FAIL=1; }
warn() { printf "  \033[33mwarn\033[0m %s\n" "$*"; }

echo "== NPU =="
if command -v npu-smi &>/dev/null; then
    if npu-smi info &>/dev/null; then
        pass "npu-smi ($(npu-smi info -l 2>/dev/null | grep -c 'NPU ID' || echo '?') devices)"
    else
        fail "npu-smi present but failing — check device mounts / driver health"
    fi
else
    fail "npu-smi not found — container missing driver mounts"
fi
ls /dev/davinci[0-9] &>/dev/null && pass "/dev/davinci* mapped" || fail "/dev/davinci* not mapped"

echo "== CANN =="
TOOLKIT="/usr/local/Ascend/ascend-toolkit/latest"
[[ -d "$TOOLKIT" ]] && pass "toolkit at $TOOLKIT" || fail "toolkit missing at $TOOLKIT"
[[ -n "${ASCEND_TOOLKIT_HOME:-}" ]] && pass "ASCEND_TOOLKIT_HOME set" \
    || warn "ASCEND_TOOLKIT_HOME unset — source /etc/ascend-env.sh"

echo "== conda =="
if [[ -d "$CONDA_DIR" ]]; then
    pass "miniforge at $CONDA_DIR"
    source "$CONDA_DIR/etc/profile.d/conda.sh"
    source "$CONDA_DIR/etc/profile.d/mamba.sh" 2>/dev/null
else
    fail "miniforge missing — wrong image? expected hcie/lab:8.0rc1-910b"
    echo; echo "$FAIL failures"; exit 1
fi

check_env() {
    local env="$1" label="$2" code="$3"
    if ! conda env list | awk '{print $1}' | grep -qx "$env"; then
        fail "env '$env' missing"
        return
    fi
    local out
    out=$(conda run -n "$env" python -c "$code" 2>&1)
    if [[ $? -eq 0 ]]; then
        pass "$label: $(echo "$out" | tail -1)"
    else
        fail "$label: $(echo "$out" | tail -2 | tr '\n' ' ')"
    fi
}

echo "== frameworks =="
check_env mindspore "mindspore" \
    'import mindspore, numpy; print(f"ms {mindspore.__version__}, numpy {numpy.__version__}")'
check_env pytorch "torch" \
    'import torch, numpy; print(f"torch {torch.__version__}, numpy {numpy.__version__}")'

# torch_npu is checked separately: importing it dlopens libascend_hal.so, which
# ships with the driver rather than the toolkit. Without that split, a missing
# wheel and a missing driver produce the same failure.
if conda env list | awk '{print $1}' | grep -qx pytorch; then
    tn=$(conda run -n pytorch pip show torch_npu 2>/dev/null | awk '/^Version:/{print $2}')
    if [[ -z "$tn" ]]; then
        fail "torch_npu wheel not installed in env 'pytorch'"
    elif out=$(conda run -n pytorch python -c \
            'import torch_npu; print(torch_npu.npu.is_available())' 2>&1); then
        pass "torch_npu $tn (npu available: $(echo "$out" | tail -1))"
    elif grep -q "libascend_hal" <<<"$out"; then
        warn "torch_npu $tn installed, but the driver is not mounted (no NPU here)"
    else
        fail "torch_npu $tn: $(echo "$out" | tail -1)"
    fi
fi

# numpy 2.x silently breaks both stacks — worth calling out explicitly.
for env in mindspore pytorch; do
    if conda env list | awk '{print $1}' | grep -qx "$env"; then
        nv=$(conda run -n "$env" python -c 'import numpy;print(numpy.__version__)' 2>/dev/null)
        [[ "$nv" == 2.* ]] && fail "env '$env' has numpy $nv — re-pin: pip install numpy==1.26.4"
    fi
done

echo "== tools =="
for t in git git-lfs aria2c unzip; do
    command -v "$t" &>/dev/null && pass "$t" || warn "$t missing"
done

echo "== lab assets =="
have() { [[ -e "$1" ]] && pass "$2" || warn "$2 (not downloaded)"; }
have "$WS/code/mindformers"                        "mindformers        (lab01,03,04,05,06)"
have "$WS/code/mindformers/research/baichuan2/belle_chat_ramdon_10k.json" \
                                                   "belle 10k dataset  (lab01)"
have "$WS/models/chatglm2-6b/.hcie-complete"       "chatglm2-6b        (lab02)"
have "$WS/models/Baichuan2-7B-Chat/.hcie-complete" "Baichuan2-7B-Chat  (lab03,05)"
have "$WS/models/Baichuan2-7B-Base/.hcie-complete" "Baichuan2-7B-Base  (lab04)"
have "$WS/models/InternLM-7B/internlm.ckpt"        "InternLM-7B        (lab06)"
have "$WS/models/glm3-6b/glm3_6b.ckpt"             "glm3-6b            (lab06)"
have "$WS/models/llava-v1.5-7b/.hcie-complete"     "llava-v1.5-7b      (lab07)"
have "$WS/code/mindone"                            "mindone            (lab08)"
have "$WS/datasets/coco2017/train2017"             "coco2017           (lab09)"

echo
if [[ $FAIL -eq 0 ]]; then
    echo "All essential checks passed."
else
    echo "Essential checks FAILED — see above."
fi
exit $FAIL

#!/usr/bin/env bash
# Host: launch the lab container with all NPUs and a persistent workspace.
# Re-running attaches to the existing container rather than creating a duplicate.
set -euo pipefail

IMAGE="${HCIE_IMAGE:-hcie/lab:8.0rc1-910b}"
NAME="${HCIE_CONTAINER:-hcie-lab}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="${HCIE_WORKSPACE:-$REPO_DIR/workspace}"

if docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
    docker start "$NAME" >/dev/null 2>&1 || true
    echo "attaching to existing container '$NAME'"
    exec docker exec -it "$NAME" bash
fi

docker image inspect "$IMAGE" >/dev/null 2>&1 || {
    echo "image '$IMAGE' not found — build it first:" >&2
    echo "  DOCKER_BUILDKIT=1 docker build -f docker/cann.dockerfile -t hcie/cann:8.0rc1-910b docker/" >&2
    echo "  docker build -f docker/lab.dockerfile -t $IMAGE docker/" >&2
    exit 1
}

mkdir -p "$WORKSPACE"/{code,models,datasets}

# Devices are passed explicitly rather than relying on ASCEND_VISIBLE_DEVICES so this
# works whether or not the Ascend Docker Runtime is the active runtime.
DEVICE_FLAGS=(--device /dev/davinci_manager --device /dev/devmm_svm --device /dev/hisi_hdc)
for i in {0..7}; do
    [[ -e /dev/davinci$i ]] && DEVICE_FLAGS+=(--device "/dev/davinci$i")
done

echo "==> Starting '$NAME'"
echo "    image:     $IMAGE"
echo "    workspace: $WORKSPACE"
echo "    npus:      $(printf '%s\n' "${DEVICE_FLAGS[@]}" | grep -c 'davinci[0-9]')"

docker run -itd \
    --name "$NAME" \
    --network host \
    --ipc host \
    --shm-size 32g \
    -p 8888:8888 \
    "${DEVICE_FLAGS[@]}" \
    -v /usr/local/Ascend/driver:/usr/local/Ascend/driver:ro \
    -v /usr/local/sbin/npu-smi:/usr/local/sbin/npu-smi:ro \
    -v /usr/local/dcmi:/usr/local/dcmi:ro \
    -v /etc/ascend_install.info:/etc/ascend_install.info:ro \
    -v "$WORKSPACE:/workspace" \
    -v "$REPO_DIR/scripts:/workspace/scripts:ro" \
    -w /workspace \
    "$IMAGE" bash >/dev/null

# --shm-size 32g: DeepSpeed and multi-worker dataloaders exhaust the 64MB default.
# --ipc host: required for the multi-card labs.

docker exec "$NAME" bash -lc 'npu-smi info' \
    || echo "WARNING: npu-smi failed inside the container — check device mounts"

cat <<EOF

Container running.

  docker exec -it $NAME bash
  bash /opt/bin/start-jupyter.sh      # JupyterLab on :8888
  bash /workspace/scripts/04-verify.sh
EOF

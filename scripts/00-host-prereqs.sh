#!/usr/bin/env bash
# Host setup: Docker + Ascend Docker Runtime. Run as root on the Atlas 800T A2.
# Does NOT install the NPU driver — version must match your firmware, install manually.
set -euo pipefail

DOCKER_VERSION="${DOCKER_VERSION:-24.0.9}"
ASCEND_RUNTIME_VERSION="${ASCEND_RUNTIME_VERSION:-6.0.RC1}"
WORK_DIR="${WORK_DIR:-/tmp/hcie-host-setup}"

[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }

echo "==> Checking NPU driver"
if ! command -v npu-smi &>/dev/null; then
    cat >&2 <<'EOF'
npu-smi not found — the NPU driver is not installed.

Install it first from Huawei support (Ascend-hdk-910b-npu-driver_*.run), matching the
firmware on this machine. CANN 8.0.RC1 expects driver 24.1.1. Then re-run this script.
EOF
    exit 1
fi
npu-smi info || { echo "npu-smi failed — driver is installed but unhealthy" >&2; exit 1; }

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo "==> Installing Docker"
if command -v docker &>/dev/null; then
    echo "docker already present: $(docker --version)"
else
    curl -fL -o docker.tgz \
        "https://mirrors.huaweicloud.com/docker-ce/linux/static/stable/aarch64/docker-${DOCKER_VERSION}.tgz"
    tar -xzf docker.tgz
    cp docker/* /usr/bin/
    rm -rf docker docker.tgz

    cat > /etc/systemd/system/docker.service <<'EOF'
[Unit]
Description=Docker Application Container Engine
After=network-online.target firewalld.service
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/dockerd
ExecReload=/bin/kill -s HUP $MAINPID
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
TimeoutStartSec=0
Delegate=yes
KillMode=process
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now docker
fi

echo "==> Installing Ascend Docker Runtime"
# The runtime injects /dev/davinci* and the host driver libs into containers, so the
# image needs no driver of its own.
RUNTIME_RUN="Ascend-docker-runtime_${ASCEND_RUNTIME_VERSION}_linux-aarch64.run"

if [[ -d /usr/local/Ascend/Ascend-Docker-Runtime ]]; then
    echo "ascend docker runtime already present"
else
    # Gitee blocks scripted downloads (no stable direct URL), so the installer must be
    # fetched by hand. Look for it next to this script or in the working dir.
    RUNTIME_PATH=""
    for candidate in "$WORK_DIR/$RUNTIME_RUN" "$(dirname "${BASH_SOURCE[0]}")/../docker/packages/$RUNTIME_RUN"; do
        [[ -f "$candidate" ]] && { RUNTIME_PATH="$candidate"; break; }
    done

    if [[ -z "$RUNTIME_PATH" ]]; then
        cat >&2 <<EOF

Ascend Docker Runtime installer not found.

Download it manually (Gitee blocks scripted access):
  https://gitee.com/ascend/ascend-docker-runtime/releases
  file: $RUNTIME_RUN

Then place it at either:
  $WORK_DIR/$RUNTIME_RUN
  <repo>/docker/packages/$RUNTIME_RUN

and re-run this script.

Alternative: skip the runtime entirely. scripts/01-run-container.sh passes
/dev/davinci* explicitly, so the labs work without it — you just lose automatic
device injection.
EOF
        exit 1
    fi

    echo "installing from $RUNTIME_PATH"
    chmod +x "$RUNTIME_PATH"
    "$RUNTIME_PATH" --install
    systemctl restart docker
fi

echo "==> Verifying"
docker info --format '{{.Runtimes}}' | grep -q ascend \
    && echo "ascend runtime registered" \
    || echo "WARNING: ascend runtime not in 'docker info' — check the install log"

cat <<EOF

Host ready.
  driver:  $(cat /usr/local/Ascend/driver/version.info 2>/dev/null | head -1 || echo unknown)
  docker:  $(docker --version)

Next: build both images, then run scripts/01-run-container.sh
  DOCKER_BUILDKIT=1 docker build -f docker/cann.dockerfile -t hcie/cann:8.0rc1-910b docker/
  docker build -f docker/lab.dockerfile -t hcie/lab:8.0rc1-910b docker/
EOF

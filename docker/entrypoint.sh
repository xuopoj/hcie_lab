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

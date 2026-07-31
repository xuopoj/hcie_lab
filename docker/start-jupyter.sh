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

#!/usr/bin/env bash
# Diagnose hfd's "failed to open the file .hfd/download.log". Run INSIDE the
# container, with the workspace mounted:
#
#   docker run --rm -v "$PWD/workspace:/workspace" \
#     -v "$PWD/scripts/diag-hfd.sh:/tmp/diag.sh:ro" \
#     hcie/lab:8.0rc1-910b bash /tmp/diag.sh
#
# See docs/superpowers/plans/2026-08-02-download-status.md for how to read it.
echo "===== identity / mount ====="
id
echo "workspace mount:"; df -hT /workspace 2>/dev/null | tail -2
echo "free space:"; df -h /workspace | tail -1
echo "read-only? "; touch /workspace/.wtest 2>&1 && echo "writable" && rm -f /workspace/.wtest

echo
echo "===== models dir state ====="
MODELS=/workspace/models
ls -lad "$MODELS" 2>&1
echo "--- existing per-repo dirs and their .hfd ---"
for d in "$MODELS"/*/; do
    [[ -d "$d" ]] || continue
    printf '%s\n' "$d"
    ls -lad "$d" "$d/.hfd" 2>&1 | sed 's/^/    /'
done

echo
echo "===== can we create .hfd as the current user? ====="
T="$MODELS/.diagtest/.hfd"
rm -rf "$MODELS/.diagtest" 2>/dev/null
if mkdir -p "$T" 2>&1; then
    echo "mkdir -p ok"
    if : > "$T/download.log" 2>&1; then echo "log file writable: yes"; else echo "log file writable: NO"; fi
else
    echo "mkdir -p FAILED — this is the root cause"
fi

echo
echo "===== aria2c with a RELATIVE log, exactly as hfd does it ====="
cd "$MODELS/.diagtest" 2>/dev/null || cd "$MODELS"
aria2c --quiet=true --log=.hfd/download.log --log-level=error --file-allocation=none \
    -o diag.bin "${HF_ENDPOINT:-https://hf-mirror.com}/robots.txt" 2>&1 | tail -3
echo "aria2c exit=$?"
rm -rf "$MODELS/.diagtest" 2>/dev/null

echo
echo "===== versions ====="
aria2c --version | head -1
echo "HF_ENDPOINT=${HF_ENDPOINT:-<unset>}"

#!/usr/bin/env bash
# Diagnose hfd's "failed to open the file .hfd/download.log".
#
# On a host (no container):
#   HCIE_WS="$HOME/hcie-workspace" bash scripts/diag-hfd.sh
#
# Inside the container, with the workspace mounted:
#   docker run --rm -v "$PWD/workspace:/workspace" \
#     -v "$PWD/scripts/diag-hfd.sh:/tmp/diag.sh:ro" \
#     hcie/lab:8.0rc1-910b bash /tmp/diag.sh
#
# See docs/superpowers/plans/2026-08-02-download-status.md for how to read it.
WS="${HCIE_WS:-/workspace}"

echo "===== identity / mount ====="
id
echo "workspace: $WS"
df -hT "$WS" 2>/dev/null | tail -2 || df -h "$WS" | tail -2
echo "read-only? "; touch "$WS/.wtest" 2>&1 && echo "writable" && rm -f "$WS/.wtest"

echo
echo "===== models dir state ====="
MODELS="$WS/models"
ls -lad "$MODELS" 2>&1
echo "--- existing per-repo dirs and their .hfd ---"
for d in "$MODELS"/*/; do
    [[ -d "$d" ]] || continue
    printf '%s\n' "$d"
    ls -lad "$d" "$d/.hfd" 2>&1 | sed 's/^/    /'
done

echo
echo "===== inspect REAL .hfd paths (four states all give the same aria2c error) ====="
# aria2c reports the identical "Failed to open ... cause: n/a" when .hfd is a file,
# when .hfd is an unwritable dir, when download.log is unwritable, and when
# download.log is itself a directory. Tell them apart by looking.
found=0
for d in "$MODELS"/*/; do
    [[ -d "$d" ]] || continue
    h="$d.hfd"; l="$h/download.log"
    [[ -e "$h" ]] || continue
    found=1
    echo "--- $d"
    echo "    .hfd:        $(ls -lad "$h" 2>&1)"
    [[ -e "$l" ]] && echo "    download.log: $(ls -lad "$l" 2>&1)" || echo "    download.log: (absent)"
    # -w can lie under root or with ACLs, so try the append hfd actually performs.
    # Only probe an existing file — never create one, or we alter what we inspect.
    wr=yes
    if [[ -f "$l" ]]; then
        ( : >> "$l" ) 2>/dev/null || wr=NO
        echo "    append works: $wr"
    fi
    if   [[ -f "$h" ]]; then echo "    VERDICT: .hfd is a FILE, not a directory  -> rm -f '$h'"
    elif [[ ! -d "$h" ]]; then echo "    VERDICT: .hfd exists but is not a directory -> rm -rf '$h'"
    elif [[ ! -w "$h" ]]; then echo "    VERDICT: .hfd dir NOT writable by $(id -un) -> chmod u+w '$h'"
    elif [[ -d "$l" ]]; then echo "    VERDICT: download.log is a DIRECTORY -> rm -rf '$l'"
    elif [[ -e "$l" && "${wr:-yes}" == NO ]]; then
        echo "    VERDICT: download.log is a regular file that cannot be written"
        echo "             owner=$(stat -c '%U:%G mode=%a' "$l" 2>/dev/null || stat -f '%Su:%Sg mode=%Lp' "$l") you=$(id -un)"
        echo "             -> rm -f '$l'    (hfd recreates it)"
    else echo "    looks usable"; fi
done
[[ $found -eq 0 ]] && echo "(no existing .hfd anywhere under $MODELS)"

echo
echo "===== can we create .hfd where hfd actually would? ====="
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
if cd "$MODELS/.diagtest" 2>/dev/null; then
    aria2c --quiet=true --log=.hfd/download.log --log-level=error --file-allocation=none \
        -o diag.bin "${HF_ENDPOINT:-https://hf-mirror.com}/robots.txt" 2>&1 | tail -3
    echo "aria2c exit=$?"
else
    echo "SKIPPED: could not cd into $MODELS/.diagtest (mkdir above failed)"
fi
rm -rf "$MODELS/.diagtest" 2>/dev/null

echo
echo "===== versions ====="
aria2c --version | head -1
echo "HF_ENDPOINT=${HF_ENDPOINT:-<unset>}"

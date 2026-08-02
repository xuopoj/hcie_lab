#!/usr/bin/env bash
# Host: package every remaining lab, one at a time, unattended.
#
#   export HCIE_STAGE_ROOT=/Volumes/HCIE/stage HCIE_PKG=/Volumes/T7/hcie-packages
#   nohup bash scripts/07-package-all.sh > /Volumes/HCIE/package-all.log 2>&1 &
#
# Skips labs already packaged, keeps going when one fails, and writes a summary
# at the end. Intended for an overnight run — one failure must not stop the rest.
set -uo pipefail   # deliberately no -e: a failed lab should not kill the run

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="${HCIE_PKG:-$HOME/hcie-packages}"
LABS="${*:-lab03 lab04 lab05 lab06 lab07 lab08 lab09 lab10}"
SUMMARY="$PKG/package-summary.txt"

mkdir -p "$PKG"
echo "run started $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$SUMMARY"

ok=0; skip=0; fail=0; failed_labs=""
for lab in $LABS; do
    zip="$PKG/hcie-$lab.zip"
    if [[ -f "$zip" ]]; then
        echo "=== $lab: already packaged ($(du -h "$zip" | cut -f1)) — skipping"
        echo "  $lab SKIP (exists)" >> "$SUMMARY"
        skip=$((skip+1)); continue
    fi

    echo
    echo "############################################################"
    echo "### $lab  starting $(date -u +%H:%M:%SZ)"
    echo "############################################################"
    start=$(date +%s)

    if bash "$HERE/05-package-lab.sh" "$lab"; then
        mins=$(( ($(date +%s) - start) / 60 ))
        echo "=== $lab: OK in ${mins}m ($(du -h "$zip" 2>/dev/null | cut -f1))"
        echo "  $lab OK ${mins}m $(du -h "$zip" 2>/dev/null | cut -f1)" >> "$SUMMARY"
        ok=$((ok+1))
    else
        mins=$(( ($(date +%s) - start) / 60 ))
        echo "=== $lab: FAILED after ${mins}m — continuing with the rest"
        echo "  $lab FAILED ${mins}m" >> "$SUMMARY"
        fail=$((fail+1)); failed_labs="$failed_labs $lab"
        # Clear a partial zip so a later run does not treat it as complete.
        rm -f "$zip" "$zip.sha256"
    fi
done

echo
echo "############################################################"
echo "### done: $ok packaged, $skip skipped, $fail failed"
[[ -n "$failed_labs" ]] && echo "### failed:$failed_labs"
echo "############################################################"
{
    echo "run finished $(date -u +%Y-%m-%dT%H:%M:%SZ): $ok ok, $skip skipped, $fail failed"
    [[ -n "$failed_labs" ]] && echo "  failed:$failed_labs"
    echo
} >> "$SUMMARY"

ls -lh "$PKG"/*.zip 2>/dev/null

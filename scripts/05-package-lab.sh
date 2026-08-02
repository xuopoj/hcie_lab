#!/usr/bin/env bash
# Host: download one lab's assets and pack them into a single zip for upload to
# ModelScope. One lab per run — the full set is ~150 GB.
#
#   bash scripts/05-package-lab.sh lab02
#   bash scripts/05-package-lab.sh lab02 --keep     # keep the staged files
#
# Stage on a CASE-SENSITIVE filesystem. HF and git repos contain files that
# differ only in case; on exFAT/APFS-insensitive they silently overwrite each
# other and the zip is quietly incomplete. On macOS with an exFAT drive:
#
#   hdiutil create -type SPARSEBUNDLE -fs "Case-sensitive APFS" -size 400g \
#       -volname HCIE /Volumes/T7/hcie-stage.sparsebundle
#   hdiutil attach /Volumes/T7/hcie-stage.sparsebundle
#   export HCIE_STAGE_ROOT=/Volumes/HCIE HCIE_PKG=/Volumes/T7/hcie-packages
set -euo pipefail

LAB="${1:-}"
KEEP=0
[[ "${2:-}" == "--keep" ]] && KEEP=1

if [[ -z "$LAB" ]]; then
    echo "usage: $0 <lab01..lab10> [--keep]" >&2
    exit 1
fi
case "$LAB" in lab0[1-9]|lab10) ;; *) echo "unknown lab: $LAB" >&2; exit 1 ;; esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE_ROOT="${HCIE_STAGE_ROOT:-$HOME/hcie-stage}"
STAGE="$STAGE_ROOT/$LAB"
PKG="${HCIE_PKG:-$HOME/hcie-packages}"
ZIP="$PKG/hcie-$LAB.zip"

mkdir -p "$STAGE" "$PKG"

echo "==> packaging $LAB"
echo "    stage: $STAGE"
echo "    out:   $ZIP"

# --- case-sensitivity guard ------------------------------------------------
# Silent data loss otherwise, so refuse rather than warn.
probe="$STAGE/.CaseProbe"; rm -f "$STAGE/.caseprobe" "$probe"
echo A > "$probe"; echo B > "$STAGE/.caseprobe" 2>/dev/null || true
if [[ "$(cat "$probe" 2>/dev/null)" != "A" ]]; then
    rm -f "$probe" "$STAGE/.caseprobe"
    echo "    REFUSING: $STAGE is on a case-INSENSITIVE filesystem." >&2
    echo "    Files differing only in case would overwrite each other." >&2
    echo "    See the header of this script for the sparse-image recipe." >&2
    exit 1
fi
rm -f "$probe" "$STAGE/.caseprobe"
echo "    case-sensitive: ok"

# --- space check -----------------------------------------------------------
# Plain case, not an associative array — macOS ships bash 3.2, which lacks them.
case "$LAB" in
    lab01|lab05) stage_need=1 ;;
    lab10)       stage_need=2 ;;
    lab02)       stage_need=13 ;;
    lab03|lab04) stage_need=15 ;;
    lab08)       stage_need=25 ;;
    lab09)       stage_need=27 ;;
    lab07)       stage_need=30 ;;
    lab06)       stage_need=40 ;;
    *)           stage_need=20 ;;
esac
avail_stage=$(df -g "$STAGE" | tail -1 | awk '{print $4}')
avail_pkg=$(df -g "$PKG" | tail -1 | awk '{print $4}')
if [[ "$avail_stage" -lt "$stage_need" ]]; then
    echo "    REFUSING: stage needs ~${stage_need} GB, has ${avail_stage} GB" >&2; exit 1
fi
if [[ "$avail_pkg" -lt "$stage_need" ]]; then
    echo "    REFUSING: package dir needs ~${stage_need} GB, has ${avail_pkg} GB" >&2; exit 1
fi
echo "    space: stage ${avail_stage} GB, packages ${avail_pkg} GB (need ~${stage_need} GB each)"

# --- download --------------------------------------------------------------
echo
echo "==> downloading assets"
# COPYFILE_DISABLE keeps macOS from writing ._* AppleDouble files into the zip.
export COPYFILE_DISABLE=1
HCIE_WS="$STAGE" bash "$HERE/03-download.sh" --lab "$LAB"

if [[ -z "$(find "$STAGE" -type f -print -quit 2>/dev/null)" ]]; then
    echo "REFUSING to package: $STAGE has no files — the download produced nothing." >&2
    exit 1
fi

# --- manifest --------------------------------------------------------------
echo
echo "==> building manifest"
MAN="$STAGE/MANIFEST.txt"
{
    echo "lab:      $LAB"
    echo "packaged: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "host:     $(uname -sm)"
    echo "size:     $(du -sh "$STAGE" | cut -f1)"
    echo
    echo "files:"
    ( cd "$STAGE" && find . -type f ! -name MANIFEST.txt -exec stat -f '%10z  %N' {} \; 2>/dev/null \
        || find . -type f ! -name MANIFEST.txt -printf '%10s  %p\n' )
} > "$MAN"
echo "    $(grep -c '\./' "$MAN" || echo 0) files, $(du -sh "$STAGE" | cut -f1)"

# --- zip -------------------------------------------------------------------
# Store-only (-0): weights are already compressed, deflate costs time for ~nothing.
# -y keeps symlinks as links. -x excludes macOS cruft.
echo
echo "==> zipping (store-only)"
rm -f "$ZIP"
( cd "$STAGE" && zip -q -r -0 -y "$ZIP" . -x '.DS_Store' '._*' '**/.DS_Store' '**/._*' )

echo "==> checksum"
( cd "$PKG" && shasum -a 256 "$(basename "$ZIP")" > "$ZIP.sha256" )

echo "==> verifying the archive"
unzip -tqq "$ZIP" && echo "    zip integrity OK"

# Cross-check the file count so a truncated zip cannot pass as complete.
zc=$(unzip -Z1 "$ZIP" | grep -vc '/$' || true)
fc=$(find "$STAGE" -type f | grep -vcE '\.DS_Store|/\._' || true)
echo "    files: $fc staged, $zc in zip"
[[ "$zc" -lt "$fc" ]] && echo "    WARNING: zip has fewer files than the stage" >&2

echo
echo "packaged: $ZIP  ($(du -h "$ZIP" | cut -f1))"
cat "$ZIP.sha256"

if [[ $KEEP -eq 0 ]]; then
    echo
    echo "==> removing staged files (pass --keep to retain)"
    rm -rf "$STAGE"
fi

echo
echo "Next: bash scripts/06-upload-modelscope.sh $LAB"

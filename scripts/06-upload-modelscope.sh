#!/usr/bin/env bash
# Host: upload one packaged lab zip to its own ModelScope dataset repo.
#
#   export MODELSCOPE_TOKEN=...          # from modelscope.cn -> Access Tokens
#   export MODELSCOPE_OWNER=your-username
#   bash scripts/06-upload-modelscope.sh lab02
#
# One repo per lab: <owner>/hcie-<lab>, holding hcie-<lab>.zip plus its .sha256.
# Re-running overwrites the file in place, so an interrupted upload is safe to retry.
#
# The token is read from the environment only — never pass it on the command line
# (it lands in shell history and ps output) and never commit it.
set -euo pipefail

LAB="${1:-}"
if [[ -z "$LAB" ]]; then
    echo "usage: $0 <lab01..lab10>" >&2
    exit 1
fi
case "$LAB" in lab0[1-9]|lab10) ;; *) echo "unknown lab: $LAB" >&2; exit 1 ;; esac

PKG="${HCIE_PKG:-$HOME/hcie-packages}"
ZIP="$PKG/hcie-$LAB.zip"
SUM="$ZIP.sha256"
OWNER="${MODELSCOPE_OWNER:-}"
REPO="${MODELSCOPE_REPO:-hcie-$LAB}"
VISIBILITY="${MODELSCOPE_VISIBILITY:-private}"   # private | internal | public
case "$VISIBILITY" in
    private|internal|public) ;;
    1) VISIBILITY=private ;; 3) VISIBILITY=internal ;; 5) VISIBILITY=public ;;
    *) echo "MODELSCOPE_VISIBILITY must be private, internal or public" >&2; exit 1 ;;
esac

if [[ -z "${MODELSCOPE_TOKEN:-}" ]]; then
    echo "MODELSCOPE_TOKEN is not set. Get one from modelscope.cn -> Access Tokens:" >&2
    echo "  export MODELSCOPE_TOKEN=..." >&2
    exit 1
fi
if [[ -z "$OWNER" ]]; then
    echo "MODELSCOPE_OWNER is not set (your ModelScope username or org):" >&2
    echo "  export MODELSCOPE_OWNER=your-username" >&2
    exit 1
fi
[[ -f "$ZIP" ]] || { echo "missing $ZIP — run scripts/05-package-lab.sh $LAB first" >&2; exit 1; }

echo "==> uploading $LAB"
echo "    zip:  $ZIP ($(du -h "$ZIP" | cut -f1))"
echo "    repo: $OWNER/$REPO (visibility=$VISIBILITY)"

# Verify the checksum before spending hours pushing a corrupt archive.
if [[ -f "$SUM" ]]; then
    echo "==> verifying checksum"
    ( cd "$PKG" && shasum -a 256 -c "$(basename "$SUM")" ) \
        || { echo "CHECKSUM MISMATCH — repackage before uploading" >&2; exit 1; }
fi

python3 - "$LAB" "$ZIP" "$SUM" "$OWNER" "$REPO" "$VISIBILITY" <<'PY'
import os, sys

lab, zip_path, sum_path, owner, repo, visibility = sys.argv[1:7]
repo_id = f"{owner}/{repo}"

try:
    from modelscope.hub.api import HubApi
    from modelscope.utils.constant import REPO_TYPE_DATASET
except ImportError:
    sys.exit("modelscope SDK missing — pip install modelscope")

api = HubApi()
try:
    api.login(os.environ["MODELSCOPE_TOKEN"])
except Exception as e:
    if "400" in str(e) or "401" in str(e):
        sys.exit("login rejected — check MODELSCOPE_TOKEN (modelscope.cn -> Access Tokens)")
    sys.exit(f"login failed: {e}")

# create_repo is idempotent in practice, but tolerate an existing repo either way.
try:
    api.create_repo(
        repo_id=repo_id,
        repo_type=REPO_TYPE_DATASET,
        visibility=visibility,   # 'private' | 'internal' | 'public'
        exist_ok=True,
    )
    print(f"    created {repo_id}")
except Exception as e:
    if "exist" in str(e).lower():
        print(f"    repo {repo_id} already exists — reusing")
    else:
        raise

for path in (zip_path, sum_path):
    if not os.path.exists(path):
        continue
    name = os.path.basename(path)
    size = os.path.getsize(path) / 1e9
    print(f"    uploading {name} ({size:.2f} GB) — this can take a while")
    api.upload_file(
        path_or_fileobj=path,
        path_in_repo=name,
        repo_id=repo_id,
        repo_type=REPO_TYPE_DATASET,
        commit_message=f"Add {name} for HCIE {lab}",
    )
    print(f"    done {name}")

print(f"\nuploaded: https://modelscope.cn/datasets/{repo_id}")
PY

echo
echo "Download it on the lab host with:"
echo "  modelscope download --dataset $OWNER/$REPO hcie-$LAB.zip --local_dir ."

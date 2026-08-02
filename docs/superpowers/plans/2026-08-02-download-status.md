# Lab Asset Download — Status and Retry Notes

**Date:** 2026-08-02
**Hosts:** Apple Silicon Mac (Docker Desktop) and a WSL2 machine
**Purpose:** where the asset download stands, what is fixed, and what to retry next.

## Summary

| Item | Status |
|---|---|
| Container-layer download bug | **Fixed**, pushed as `91ba63e` |
| lab01 assets | **Downloaded** and verified persistent (90 MB) |
| lab02–lab10 assets | **Not downloaded** — blocked on disk space |
| WSL `hfd` failure | **Open** — cause not yet identified |

---

## 1. Fixed: downloads vanishing into the container layer

`entrypoint.sh` symlinks the baked `/opt/mindformers` into `/workspace/code/`.
`fetch()` wrote lab assets *through* that symlink into the container's writable
layer instead of the bind mount, so every download was discarded when the
container exited — while the script still printed "lab ready".

Affected every lab calling `mindformers_zip`: **lab01, lab03, lab04, lab05, lab06**.
Masked by a long-lived container, which is why the 2026-07-28 build-host
verification did not catch it.

`mindformers_zip` now materialises the symlink into a real directory before
writing, the case `entrypoint.sh` already anticipates ("a real clone in the
workspace always wins").

**Verification:** stubbed-fetcher harness across all ten labs — 5 fail before the
change, 10 pass after. lab01 additionally confirmed end-to-end with real
downloads surviving a `--rm` run.

> Assets downloaded through the old code path are already lost. The five labs
> above will re-download on the next run. That is expected, not a regression.

### Caveats on that verification

- The harness **stubs the network fetchers**. It proves destination paths resolve
  to the bind mount; it does *not* check URLs, checksums or unzip behaviour.
- **lab01 is the only lab confirmed with real bytes.**
- **lab02 is partially covered.** Its `cp -r` from the cloned repo fails under
  stubs, aborting the lab under `set -e`, so `fetch_zip` and `hf_download` never
  ran. Both destinations were verified separately — they resolve inside the mount
  and survive `--rm`.

---

## 2. Open: WSL `hfd` failure

```
failed to open the file .hfd/download.log cause:n/a
```

Raised by `aria2c` inside `hfd.sh`, which passes a **relative** `--log=.hfd/download.log`
after `cd "$LOCAL_DIR"` (hfd.sh line 321). The error appears when `.hfd/` does not
exist or cannot be opened at that point.

`hfd.sh` creates it unconditionally at line 103 (`mkdir -p "$LOCAL_DIR/.hfd"`),
with **no error check** — so a failing `mkdir` surfaces later as this confusing
aria2c message rather than a clear "cannot create directory".

### Ruled out by testing

| Theory | Result |
|---|---|
| Workspace on `/mnt/c` (9p/drvfs) | **No** — user confirmed it is on the home dir |
| Relative vs absolute `LOCAL_DIR` mismatch | **No** — both resolve identically; our script passes an absolute `--local-dir` |
| `hfd.sh` deleting `.hfd` mid-run | **No** — only individual files are removed, no destructive trap |
| `file-allocation` not set | **No** — already `none` in `docker/aria2c.conf` |

Reproduced the exact error on macOS by removing `.hfd/` before invoking aria2c,
which confirms the mechanism but not the WSL-specific trigger.

### Leading hypothesis (unconfirmed)

A **stale `.hfd/` owned by a different uid** from an earlier run. `mkdir -p`
succeeds silently on an existing directory while the log open still fails.

### Next step

Run `scripts/diag-hfd.sh` inside the container on the WSL host:

```bash
cd ~/hcie_lab
docker run --rm -v "$PWD/workspace:/workspace" \
  -v "$PWD/scripts/diag-hfd.sh:/tmp/diag.sh:ro" \
  hcie/lab:8.0rc1-910b bash /tmp/diag.sh
```

Interpreting the output:

| Failing check | Cause |
|---|---|
| `read-only?` not "writable" | Bind mount is read-only |
| `free space` near 0 | Disk full — aria2c cannot create the log |
| `mkdir -p FAILED` | Permissions on `models/` |
| existing `.hfd` owned by another uid | Stale dir — `rm -rf workspace/models/*/.hfd` |
| `mkdir` ok but log not writable | Filesystem / ACL issue |
| all pass, aria2c still errors | aria2c-level; inspect `docker/aria2c.conf` |

Baseline on the Mac: every check passes, aria2c exits 0.

> This is **independent** of the symlink bug. `hf_download` writes to `$MODELS`,
> which never crossed the mindformers symlink, and passed the plumbing test both
> before and after the fix.

---

## 3. Blocked: disk space

`--lab all` needs **~150 GB**; the Mac has **~51 GB** free. A full run cannot
complete and would fill the disk.

Reclaimed 26.6 GB on 2026-08-02 via `docker image prune` (dangling only) plus
`docker builder prune`. A further ~47 GB of Docker images is reclaimable but was
left alone — it includes running VPN containers and volumes holding real data
(grafana/loki/prometheus, jupyterhub, a postgres volume).

What fits in ~51 GB:

| Labs | Size | Fits |
|---|---|---|
| lab01 | ~20 MB | done |
| lab01 + lab02 | ~13 GB | yes |
| lab03 + lab04 + lab05 | ~30 GB | tight |
| lab06 alone | ~40 GB | ~11 GB headroom |
| all | ~150 GB | **no** |

The Mac cannot run the labs anyway (no NPU). Bulk downloads belong on the
Atlas 800T A2.

---

## 4. Retry checklist

- [ ] Run `diag-hfd.sh` on WSL; fix per the table above
- [ ] Re-run the five affected labs so assets land on the mount for real
- [ ] Decide where bulk assets live — Atlas host, not the Mac
- [ ] Free space or pick a subset before anything beyond lab01+lab02
- [ ] Verify lab02's `fetch_zip` / `hf_download` with real bytes (stub-blocked)
- [ ] Consider a fail-fast check in `hf_download` for an unwritable destination

## 5. Known-good commands

```bash
# lab01 end-to-end, assets persist on the host (verified 2026-08-02)
docker run --rm \
  -v "$PWD/workspace:/workspace" \
  -v "$PWD/scripts:/opt/hcie-scripts:ro" \
  hcie/lab:8.0rc1-910b \
  bash /opt/hcie-scripts/03-download.sh --lab lab01
```

> `scripts/01-run-container.sh` does **not** work on macOS — it mounts
> `/dev/davinci*` and Ascend driver paths that do not exist there. Use it on the
> Atlas host; use the direct `docker run` above for download testing off-NPU.

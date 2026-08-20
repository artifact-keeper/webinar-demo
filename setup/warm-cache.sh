#!/usr/bin/env bash
# Pre-pull every artifact the demo touches so nothing on the webinar depends
# on a cold upstream fetch. Run this inside the JupyterLab terminal, where
# pip and hf are already pointed at Artifact Keeper. Safe to re-run against a
# fresh database; see pip_download_tolerating_scan_block below for the one
# case where "re-run" means "against a database that already ran Act 2."
set -euo pipefail
cd "$(dirname "$0")/.."

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# configure.sh deliberately leaves scan_on_proxy off during setup so a fresh
# database can warm pyyaml==5.3 and urllib3==1.24.1 through the proxy --
# Act 2 step 1 is what flips scan_on_proxy on, live, as part of its own
# narrative. But that flip persists in the database (it is not undone by a
# plain stop/start, only by a full `down -v` or setup/reset.sh), and once
# it's on it inline-scans every file served through the proxy, not just the
# one Act 2 named -- so bringing the stack back up a second time without a
# full wipe hits the same 403 scan_blocked gate for any warm target that
# happens to carry real findings (both pyyaml==5.3 and urllib3==1.24.1 do;
# that is the whole point of using them here). That is not a failure to
# warm the cache -- it is proof the file is already cached and already
# recorded vulnerable from the prior run, which is exactly the state Act 2
# needs. Only a genuine failure (network, upstream, a renamed/missing
# package) should stop this script; a 403 here should not.
pip_download_tolerating_scan_block() {
  local errfile; errfile="$(mktemp)"
  if ! pip download --no-deps -d "$TMP" "$@" 2>"$errfile"; then
    if grep -q "403" "$errfile"; then
      echo "Already cached and scan-blocked from a prior Act 2 run -- nothing to warm, continuing."
    else
      cat "$errfile" >&2
      rm -f "$errfile"
      exit 1
    fi
  fi
  rm -f "$errfile"
}

echo "== pip: requests (Act 1 cold open) =="
pip download requests --no-deps -d "$TMP"

echo "== pip: pyyaml 5.3 (Act 2 rescan target: cached BEFORE any policy looked at it) =="
pip_download_tolerating_scan_block pyyaml==5.3

echo "== pip: urllib3 1.24.1 wheel (Act 2 rescan target: cached BEFORE any policy looked at it) =="
pip_download_tolerating_scan_block urllib3==1.24.1 --only-binary :all:

echo "== hugging face: sentence-transformers/all-MiniLM-L6-v2 (Act 1 model moment) =="
HF_HOME="$TMP/hf" hf download sentence-transformers/all-MiniLM-L6-v2 --max-workers 2

cat <<'EOF'

WARM CACHE COMPLETE.
  [x] pip: requests, pyyaml==5.3 (via pypi-proxy)
  [x] pip: urllib3==1.24.1 wheel (via pypi-proxy, Act 2 rescan target)
  [x] huggingface: sentence-transformers/all-MiniLM-L6-v2 (via hf-proxy)

Not warmed on purpose:
  - requessts* (blocked by curation before any upstream fetch, Act 1)
  - the age-gate package (blocked before any upstream fetch, Act 3)
  - the Act 1 CVE wheel (published fresh on every run, unique filename)
EOF

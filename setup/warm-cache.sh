#!/usr/bin/env bash
# Pre-pull every artifact the demo touches so nothing on the webinar depends
# on a cold upstream fetch. Run this inside the JupyterLab terminal, where
# pip and hf are already pointed at Artifact Keeper. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")/.."

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "== pip: requests (Act 1 cold open) =="
pip download requests --no-deps -d "$TMP"

echo "== pip: pyyaml 5.3 (Act 2 rescan target: cached BEFORE any policy looked at it) =="
pip download pyyaml==5.3 --no-deps -d "$TMP"

echo "== pip: urllib3 1.24.1 wheel (Act 2 rescan target: cached BEFORE any policy looked at it) =="
pip download urllib3==1.24.1 --no-deps --only-binary :all: -d "$TMP"

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

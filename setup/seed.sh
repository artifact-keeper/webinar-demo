#!/usr/bin/env bash
# One-shot seeder. Runs inside the seed container on every compose up:
# waits for the backend, then configures the registry and warms the caches.
# Both steps are idempotent, so re-runs are fast no-ops.
set -euo pipefail
cd /home/jovyan/work

echo "== Waiting for the backend =="
for i in $(seq 1 90); do
  if curl -fsS "${AK_URL}/health" >/dev/null 2>&1; then break; fi
  sleep 2
done
curl -fsS "${AK_URL}/health" >/dev/null || { echo "Backend never became healthy"; exit 1; }

bash setup/configure.sh
bash setup/warm-cache.sh

echo "SEED COMPLETE: registry configured, caches warm. Open JupyterLab and run the acts."

#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

set -a
source stack/.env
[ -f stack/.env.local ] && source stack/.env.local
set +a

AK_URL="${AK_URL:-http://localhost:${AK_API_PORT}}"
AK_WEB_URL="${AK_WEB_URL:-http://localhost:${AK_WEB_PORT}}"

compose_args=(--env-file stack/.env)
[ -f stack/.env.local ] && compose_args+=(--env-file stack/.env.local)
compose_args+=(-f stack/docker-compose.yml)

echo "== Tool checks =="
for tool in docker curl; do
  command -v "$tool" >/dev/null || { echo "MISSING: $tool"; exit 1; }
done
command -v jq >/dev/null || echo "WARNING: jq not found; setup/reset.sh needs it, everything else works without it"

echo "== Pull images =="
docker compose "${compose_args[@]}" pull scan-workspace-init postgres opensearch trivy backend web \
  || echo "pull failed for some images; up -d will retry"

echo "== Build Jupyter image =="
docker compose "${compose_args[@]}" build jupyter

echo "== Start stack =="
docker compose "${compose_args[@]}" up -d

echo "== Wait for backend health =="
healthy=""
for i in $(seq 1 60); do
  if curl -fsS "${AK_URL}/health" >/dev/null 2>&1; then
    healthy=1
    break
  fi
  sleep 2
done

if [ -z "$healthy" ]; then
  echo "Backend did not become healthy in 120s"
  exit 1
fi

echo "Backend healthy."

echo "== Wait for seed =="
seed_container="${AK_NAME_PREFIX:-webinar-demo}-seed"
seed_done=""
missing_count=0
last_status=""
for i in $(seq 1 300); do
  status=$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$seed_container" 2>/dev/null || true)
  if [ -z "$status" ]; then
    missing_count=$((missing_count + 1))
    if [ "$missing_count" -ge 15 ]; then
      echo "Seed container ${seed_container} was never created. Re-run with the compose files this repo ships (see README) or check AK_NAME_PREFIX."
      exit 1
    fi
  else
    missing_count=0
    last_status="$status"
    if [ "${status%% *}" = "exited" ]; then
      seed_done=1
      break
    fi
  fi
  sleep 2
done

if [ -z "$seed_done" ]; then
  echo "Seed did not finish within 10 minutes (last seen status: ${last_status:-none})"
  exit 1
fi

seed_exit="${last_status##* }"
if [ "$seed_exit" = "0" ]; then
  echo "Seed complete."
else
  echo "Seed failed (exit $seed_exit). Last 40 lines of seed logs:"
  docker logs --tail 40 "$seed_container" || true
  exit 1
fi

echo
echo "API:      ${AK_URL}"
echo "Web:      ${AK_WEB_URL}"
echo "Jupyter:  http://localhost:${AK_JUPYTER_PORT}/lab?token=artifact-keeper-demo"

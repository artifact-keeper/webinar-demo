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
for tool in docker jq curl; do
  command -v "$tool" >/dev/null || { echo "MISSING: $tool"; exit 1; }
done

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
echo
echo "API:      ${AK_URL}"
echo "Web:      ${AK_WEB_URL}"
echo "Jupyter:  http://localhost:${AK_JUPYTER_PORT}/lab?token=artifact-keeper-demo"

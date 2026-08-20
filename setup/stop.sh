#!/usr/bin/env bash
# Stops the stack without touching data: containers go away, the named
# volumes (registry data, proxy cache, everything the seed warmed) stay put.
# `start.sh` afterward resumes from exactly where this left off -- that is
# the difference from a reset. For a genuinely clean slate (the one thing
# this script deliberately does NOT do), see README.md's "Start over"
# section: `docker compose ... down -v` followed by `start.sh`.
set -euo pipefail
cd "$(dirname "$0")/.."

compose_args=(--env-file stack/.env)
[ -f stack/.env.local ] && compose_args+=(--env-file stack/.env.local)
compose_args+=(-f stack/docker-compose.yml)

echo "== Stopping stack (data preserved) =="
docker compose "${compose_args[@]}" down

echo
echo "Stopped. Volumes are untouched -- run setup/start.sh to bring it back"
echo "up with the same data. For a full wipe instead, see README.md's"
echo "\"Start over\" section (docker compose ... down -v)."

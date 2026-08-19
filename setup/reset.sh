#!/usr/bin/env bash
# Runs on the HOST (not in a container): it needs `docker exec` against the
# stack's db container to clear the age-gate review queue.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
# Abort on a failed login: continuing would 401 every call while the script
# printed its narration, i.e. a demo that looks fine and does nothing.
ak_login || exit 1
export AK_API_ALLOW_FAIL=1

echo "== Delete team-packages (live-created repo) =="
ak_api DELETE /api/v1/repositories/team-packages >/dev/null; echo deleted

echo "== Disable age gate on pypi-proxy =="
ak_api PUT /api/v1/repositories/pypi-proxy/age-gate '{"enabled": false, "min_age_days": 14}' >/dev/null; echo done

echo "== Disable curation enforcement on pypi-proxy =="
ak_api PATCH /api/v1/repositories/pypi-proxy \
  '{"curation_enabled": false, "curation_default_action": "allow"}' >/dev/null; echo done

echo "== Delete curation rules created by configure.sh =="
for id in $(ak_api GET /api/v1/curation/rules | jq -r '(if type=="array" then . else .items end) | map(select(.package_pattern=="requessts*")) | .[].id'); do
  ak_api DELETE "/api/v1/curation/rules/${id}" >/dev/null; echo "rule ${id} deleted"
done

echo "== Delete demo-cve-gate and demo-global-cve scan policies =="
for id in $(ak_api GET /api/v1/security/policies | jq -r '(if type=="array" then . else .items end) | map(select(.name=="demo-cve-gate" or .name=="demo-global-cve")) | .[].id'); do
  ak_api DELETE "/api/v1/security/policies/${id}" >/dev/null; echo "policy ${id} deleted"
done

echo "== Clear age-gate review queue =="
# Age-gate approvals are permanent and there is no un-approve API, so a version
# approved during a prior rehearsal would serve 200 instead of the 451 the demo
# needs (Act 3 Moment 2). There is no HTTP endpoint to wipe reviews, so clear
# the table directly in the demo Postgres container. Best-effort: skip quietly
# if the container is not reachable (e.g. a differently named stack).
#
# Note: proxy-cache scan state (vulnerable / not_scanned) on cached artifacts
# in pypi-proxy also persists across this reset and has no wipe API either.
# This script does not attempt to clear it. A fully pristine Act 2 state
# needs `docker compose ... down -v` plus a full re-run of setup/configure.sh,
# or exercising Act 2 against a different package version each rehearsal.
DB_CONTAINER="${AK_NAME_PREFIX:-webinar-demo}-db"
if docker exec "$DB_CONTAINER" psql -U registry -d artifact_registry -c "DELETE FROM age_gate_reviews;" >/dev/null 2>&1; then
  echo "age-gate reviews cleared (${DB_CONTAINER})"
else
  echo "age-gate reviews NOT cleared (container ${DB_CONTAINER} unreachable); if a version was approved before, Act 3 Moment 2 may serve 200 instead of 451"
fi

echo "RESET COMPLETE: run setup/configure.sh to rebuild live."

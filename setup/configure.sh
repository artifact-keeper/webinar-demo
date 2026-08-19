#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
# Abort on a failed login: continuing would 401 every call while the script
# printed its narration, i.e. a demo that looks fine and does nothing.
ak_login || exit 1

create_repo() { # key name format type upstream(optional)
  local key="$1" name="$2" format="$3" rtype="$4" upstream="${5:-}"
  if ak_api GET "/api/v1/repositories/${key}" >/dev/null 2>&1; then
    echo "repo ${key}: already exists"
    return 0
  fi
  local body
  body=$(jq -n --arg k "$key" --arg n "$name" --arg f "$format" \
              --arg t "$rtype" --arg u "$upstream" \
    '{key:$k, name:$n, format:$f, repo_type:$t, is_public:true}
     + (if $u != "" then {upstream_url:$u} else {} end)')
  ak_api POST /api/v1/repositories "$body" | jq -r '"repo \(.key): created"'
}

echo "== Proxy repositories =="
create_repo pypi-proxy    "PyPI (proxied)"          pypi        remote https://pypi.org
create_repo hf-proxy      "Hugging Face (proxied)"  huggingface remote https://huggingface.co
echo "== Internal repository (created live) =="
create_repo team-packages "Team Packages" pypi local

echo "== Age gate on pypi-proxy (14 days) =="
ak_api PUT /api/v1/repositories/pypi-proxy/age-gate \
  '{"enabled": true, "min_age_days": 14}' | jq -c .

echo "== Enable curation enforcement on pypi-proxy =="
ak_api PATCH /api/v1/repositories/pypi-proxy \
  '{"curation_enabled": true, "curation_default_action": "allow"}' \
  | jq -c '{key, curation_enabled}'

echo "== Curation rule: block typosquats =="
existing=$(ak_api GET /api/v1/curation/rules \
  | jq -r '(if type=="array" then . else .items end) | map(select(.package_pattern=="requessts*")) | length')
if [ "$existing" = "0" ]; then
  ak_api POST /api/v1/curation/rules \
    '{"package_pattern":"requessts*","action":"block","priority":10,"reason":"Typosquat of requests: blocked by policy"}' | jq -c .
else
  echo "curation rule already exists"
fi

echo "== Scan policy: quarantine high/critical CVEs on pypi-proxy =="
# repository-scoped policy on pypi-proxy. On 1.8.0 this powers the
# serve-time scan_blocked gate that blocks downloads of proxy-cached
# artifacts flagged vulnerable by a rescan (verified live). Load-bearing
# for Act 2, not dead weight.
repo_id=$(ak_repo_id pypi-proxy)
have=$(ak_api GET /api/v1/security/policies \
  | jq -r '(if type=="array" then . else .items end) | map(select(.name=="demo-cve-gate")) | length')
if [ "$have" = "0" ]; then
  ak_api POST /api/v1/security/policies \
    "{\"name\":\"demo-cve-gate\",\"repository_id\":\"${repo_id}\",\"max_severity\":\"high\",\"block_unscanned\":false,\"block_on_fail\":true}" | jq -c .
else
  echo "scan policy already exists"
fi

echo "== Scan policy: global CVE gate covering hosted repos (team-packages) =="
# repository_id: null makes this a global policy (PolicyService::evaluate_artifact
# matches repo-specific OR NULL). This is the policy Act 3 Moment 3 relies on
# to auto-quarantine a scanned artifact in team-packages.
have_global=$(ak_api GET /api/v1/security/policies \
  | jq -r '(if type=="array" then . else .items end) | map(select(.name=="demo-global-cve")) | length')
if [ "$have_global" = "0" ]; then
  ak_api POST /api/v1/security/policies \
    '{"name":"demo-global-cve","repository_id":null,"max_severity":"high","block_unscanned":false,"block_on_fail":true}' | jq -c .
else
  echo "global scan policy already exists"
fi

echo "CONFIGURED: registry ready for the demo."

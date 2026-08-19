#!/usr/bin/env bash
# Shared helpers for demo automation. Source, do not execute.
DEMO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${DEMO_ROOT}/stack/.env"
if [ -f "${DEMO_ROOT}/stack/.env.local" ]; then
  source "${DEMO_ROOT}/stack/.env.local"
fi
# Environment-preset URLs win (the Jupyter container presets both);
# otherwise derive from the effective ports.
AK_URL="${AK_URL:-http://localhost:${AK_API_PORT:-8080}}"
AK_WEB_URL="${AK_WEB_URL:-http://localhost:${AK_WEB_PORT:-3000}}"

# Acquire an admin token, reusing one from the environment when it is still
# valid. The demo runs several scripts back to back and the login endpoint
# rate-limits per IP: a rehearsal that logs in once per script used to trip a
# 429, and the empty token that produced then 401'd every subsequent call while
# the scripts happily printed their narration, i.e. a demo that looks like it
# works and does nothing. Reuse plus a 429-aware retry removes that whole class
# of failure. Export AK_TOKEN before running the scripts (the notebooks do) and
# every one of them shares a single login.
ak_login() {
  if [ -n "${AK_TOKEN:-}" ] \
     && curl -fsS -o /dev/null -H "Authorization: Bearer ${AK_TOKEN}" \
        "${AK_URL}/api/v1/repositories?per_page=1" 2>/dev/null; then
    export AK_TOKEN
    return 0
  fi

  local attempt raw code json wait_for
  for attempt in 1 2 3; do
    raw=$(curl -sS -D "/tmp/ak-login-headers.$$" -w '\n%{http_code}' \
      -X POST "${AK_URL}/api/v1/auth/login" \
      -H 'Content-Type: application/json' \
      -d "{\"username\":\"${AK_ADMIN_USER}\",\"password\":\"${AK_ADMIN_PASSWORD}\"}" 2>/dev/null)
    code=$(printf '%s' "$raw" | tail -n1)
    json=$(printf '%s' "$raw" | sed '$d')

    if [ "$code" = "200" ]; then
      AK_TOKEN=$(printf '%s' "$json" | jq -r '.token // .access_token // empty')
      if [ -n "$AK_TOKEN" ] && [ "$AK_TOKEN" != "null" ]; then
        rm -f "/tmp/ak-login-headers.$$"
        export AK_TOKEN
        return 0
      fi
    fi

    if [ "$code" = "429" ] && [ "$attempt" -lt 3 ]; then
      # Honour Retry-After when the server sends it, capped so a demo never
      # blocks for minutes on end.
      wait_for=$(grep -i '^retry-after:' "/tmp/ak-login-headers.$$" 2>/dev/null \
        | tr -d '\r' | awk '{print $2}' | head -1)
      case "$wait_for" in ''|*[!0-9]*) wait_for=20 ;; esac
      [ "$wait_for" -gt 90 ] && wait_for=90
      echo "login rate-limited (429); waiting ${wait_for}s then retrying" >&2
      sleep "$wait_for"
      continue
    fi
    break
  done

  rm -f "/tmp/ak-login-headers.$$"
  echo "LOGIN FAILED (last HTTP status: ${code:-unknown}). Not continuing: every" >&2
  echo "later API call would 401 and the demo would narrate steps that never ran." >&2
  echo "If this is a 429, wait for the rate limit to clear and rerun." >&2
  return 1
}

ak_api() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS -X "$method" "${AK_URL}${path}" -H "Authorization: Bearer ${AK_TOKEN}")
  [ -n "$body" ] && args+=(-H 'Content-Type: application/json' -d "$body")
  [ "${AK_API_ALLOW_FAIL:-0}" = "1" ] || args+=(-f)
  curl "${args[@]}"
}

ak_repo_id() {
  ak_api GET "/api/v1/repositories/$1" | jq -r '.id'
}

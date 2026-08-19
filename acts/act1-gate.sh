#!/usr/bin/env bash
# Act 1: the gate holds. Three numbered steps showing the registry
# enforcing against the live stack, every EXPECTED line verified against a
# running 1.8.0 instance: normal life is unchanged (cold open), a typosquat
# is blocked before any upstream fetch (curation), and a package with a
# known CVE auto-quarantines the moment its scan completes (scan policy).
set -uo pipefail   # deliberately no -e: a 4xx/5xx response IS the demo
source "$(dirname "$0")/../setup/lib.sh"

PIP_INDEX="${PIP_INDEX_URL:-${AK_URL}/pypi/pypi-proxy/simple}"
# One of the few prebuilt wheels PyPI published for 5.3 -- needed because a
# bare sdist tarball did not get parsed for CVEs (a wheel's dist-info layout
# is what the scanner's cataloger needs). We never install it, only scan it;
# its Windows platform tag is irrelevant to CVE matching.
CVE_WHEEL_URL="https://files.pythonhosted.org/packages/e9/37/8b3b8468894fb9ae31cac2a1ecec2f66514d1eec592c0e7d169bd3e1859e/PyYAML-5.3-cp38-cp38-win_amd64.whl"
# The uploaded filename carries a random PEP 427 build-tag segment (the
# "-1<rand>-" between version and python tag) so every run publishes to a
# never-before-used path in team-packages. Re-publishing the exact same
# path+digest after deleting it resurrects the old artifact row with its
# prior quarantine_status/scan history instead of starting clean
# (team-packages' delete is a soft-delete), which makes repeat runs of this
# script flaky. The wheel's internal dist-info still says version 5.3, so
# the CVE match is unaffected; only the storage path/filename is unique.
CVE_RUN_TAG="$RANDOM"
CVE_WHEEL_NAME="PyYAML-5.3-1${CVE_RUN_TAG}-cp38-cp38-win_amd64.whl"
CVE_DOWNLOAD_URL="${AK_URL}/pypi/team-packages/simple/pyyaml/${CVE_WHEEL_NAME}"

DL=$(mktemp -d); trap 'rm -rf "$DL"' EXIT

# Run one step at a time, or all of them. `bash act1-gate.sh 2` runs only
# step 2; no argument runs the whole act. Single-step mode is what the
# Jupyter notebook uses: one cell per step, so notebook cell boundaries
# replace the interactive pauses below.
STEP="${STEP:-${1:-all}}"
want() { [ "$STEP" = "all" ] || [ "$STEP" = "$1" ]; }

# Only prompt when running the whole act interactively. In single-step mode
# there is nothing to pause for, and with no TTY (a notebook cell, a pipe, CI)
# `read` returns instantly, which would silently blast through every step.
pause() {
  [ "$STEP" = "all" ] || return 0
  [ -t 0 ] || return 0
  read -rp $'\n[enter for next step]\n'
}
freshdir() { local d; d=$(mktemp -d "$DL/dl.XXXXXX"); echo "$d"; }

# Find the most recent live pyyaml artifact in team-packages. The `release`
# step needs the id step 3 published, but in single-step mode each
# invocation is its own process, so the variable is gone: look it up instead.
latest_team_pyyaml_row() {
  ak_api GET /api/v1/repositories/team-packages/artifacts \
    | jq -r '[(.items // .)[] | select(.path | test("pyyaml"; "i"))]
             | sort_by(.created_at) | reverse | .[0]
             | "\(.id)\t\(.path)" // empty'
}

# GET a URL and print its status line plus body -- but only when the body is
# small text/JSON. Guards a live demo against ever dumping a multi-MB binary
# artifact to the terminal if a probe unexpectedly succeeds (e.g. a package
# that turns out to already be released from an earlier run).
show_get() {
  local url="$1" body_file headers_file code ctype size
  body_file=$(mktemp "$DL/body.XXXXXX")
  headers_file=$(mktemp "$DL/headers.XXXXXX")
  code=$(curl -sS -o "$body_file" -D "$headers_file" -w '%{http_code}' "$url")
  ctype=$(grep -i '^content-type:' "$headers_file" | tail -1 | tr -d '\r' | cut -d' ' -f2-)
  size=$(wc -c < "$body_file" | tr -d ' ')
  echo "HTTP $code"
  case "$ctype" in
    application/json*|text/*)
      cat "$body_file"; echo
      ;;
    *)
      echo "(${size} bytes, content-type: ${ctype:-unknown} -- not a text/JSON body, not printed)"
      ;;
  esac
}

# Abort on a failed login: continuing would 401 every call while the script
# printed its narration, i.e. a demo that looks fine and does nothing.
ak_login || exit 1

if want 1; then
echo "--- ACT 1.1: normal life, unchanged ---"
echo "\$ pip download requests   (through Artifact Keeper's pypi-proxy)"
time pip download requests --no-deps -d "$(freshdir)"
echo
echo "\$ hf download sentence-transformers/all-MiniLM-L6-v2   (model weights, same governed front door)"
HF_HOME=$(mktemp -d "$DL/hf.XXXXXX") hf download sentence-transformers/all-MiniLM-L6-v2 --max-workers 2
echo
echo "Both served warm from the registry cache. The developer changed nothing"
echo "about their workflow; the registry is just where packages come from now."
pause
fi

if want 2; then
echo "--- ACT 1.2: typosquat (curation) ---"
echo "\$ pip install requessts"
pip download requessts --index-url "$PIP_INDEX" --no-deps -d "$(freshdir)"
echo
echo "pip's own message is unhelpful ('no matching distribution') -- looks like"
echo "a plain miss. Here is what actually happened on the wire:"
echo
echo "\$ curl -i ${PIP_INDEX}/requessts/"
show_get "${PIP_INDEX}/requessts/"
echo
echo "EXPECTED: HTTP 403, body {\"error\":\"curation_blocked\",\"package\":"
echo "\"requessts\",\"reason\":\"...\"}. A curation block rule for 'requessts*' is"
echo "configured (GET /api/v1/curation/rules) and is enforced directly on the"
echo "PyPI proxy's simple-index and download paths, before any upstream fetch."
pause
fi

if want 3; then
echo "--- ACT 1.3: known-CVE package (the centerpiece) ---"
echo "\$ pip install pyyaml==5.3"
pip download pyyaml==5.3 --index-url "$PIP_INDEX" --no-deps -d "$(freshdir)"
echo
echo "(succeeds: pyyaml 5.3 is a 2020 release, well past the age gate window --"
echo " and proxy-cached artifacts are never scan-eligible, so nothing here"
echo " evaluates it for CVEs. To see real CVE enforcement we publish the same"
echo " package internally, to the hosted team-packages repo, where a global"
echo " scan policy (demo-global-cve, max_severity=high, block_on_fail=true)"
echo " actually applies.)"
echo
echo "\$ (admin) publishing pyyaml 5.3 to the internal team-packages repo..."
CVE_WHEEL_FILE="$DL/$CVE_WHEEL_NAME"
curl -fsS -o "$CVE_WHEEL_FILE" "$CVE_WHEEL_URL"
CVE_SHA256=$(shasum -a 256 "$CVE_WHEEL_FILE" | awk '{print $1}')
curl -sS -u "${AK_ADMIN_USER}:${AK_ADMIN_PASSWORD}" \
  -F ":action=file_upload" -F "name=PyYAML" -F "version=5.3" \
  -F "sha256_digest=${CVE_SHA256}" \
  -F "content=@${CVE_WHEEL_FILE};type=application/octet-stream" \
  "${AK_URL}/pypi/team-packages/" >/dev/null

CVE_ARTIFACT_ID=$(ak_api GET /api/v1/repositories/team-packages/artifacts \
  | jq -r --arg f "$CVE_WHEEL_NAME" '(.items // .)[] | select(.path | contains($f)) | .id' | head -1)
echo "artifact_id=${CVE_ARTIFACT_ID:-<not found>}"

echo
echo "\$ curl -o /dev/null -w '%{http_code}\n' (download, pre-scan)"
curl -sS -o /dev/null -w '%{http_code}\n' "$CVE_DOWNLOAD_URL"
echo "EXPECTED: 200 -- nothing has scanned it yet, so nothing has flagged it yet."

if [ -n "${CVE_ARTIFACT_ID:-}" ]; then
  SCAN_IDS=$(ak_api POST /api/v1/security/scan "{\"artifact_id\":\"${CVE_ARTIFACT_ID}\"}" | jq -r '.scan_result_ids[]?')
  echo
  echo "\$ scanning..."
  for _ in 1 2 3 4 5 6 7 8; do
    sleep 2
    STILL_RUNNING=0
    for id in $SCAN_IDS; do
      status=$(ak_api GET "/api/v1/security/scans/${id}" 2>/dev/null | jq -r '.status // "unknown"')
      [ "$status" = "queued" ] || [ "$status" = "running" ] && STILL_RUNNING=1
    done
    [ "$STILL_RUNNING" = "0" ] && break
  done
  echo
  echo "Findings:"
  for id in $SCAN_IDS; do
    ak_api GET "/api/v1/security/scans/${id}/findings" 2>/dev/null \
      | jq -r '(.items // [])[] | "  \(.severity | ascii_upcase)  \(.cve_id)  \(.title)  (fixed in \(.fixed_version // "n/a"))"'
  done
  echo
  echo "Quarantine status:"
  ak_api GET "/api/v1/quarantine/${CVE_ARTIFACT_ID}" | jq -c .
fi

echo
echo "\$ curl -i (download, post-scan)"
show_get "$CVE_DOWNLOAD_URL"
echo
echo "EXPECTED: a critical finding, CVE-2020-14343 (arbitrary code execution via"
echo "yaml.load/FullLoader, fixed in 5.4), and CVE-2020-1747 (fixed in 5.3.1). The"
echo "artifact auto-quarantines the moment the scan completes, and the download"
echo "above is now HTTP 409 CONFLICT (\"Artifact is quarantined and pending"
echo "security review\"). The policy name and finding count are on the"
echo "quarantine record printed just above, not in the 409 body itself."
echo
echo "Artifact is HELD. Open the UI to see it and release it there:"
echo "  ${AK_WEB_URL}/repositories  ->  team-packages  ->  pyyaml"
echo "(fallback: bash acts/act1-gate.sh release)"
pause
fi

# Rediscovers the artifact step 3 published, exactly the way step 3's own
# lookup does -- runs in its own process from a notebook cell or a later
# terminal invocation, so step 3's CVE_ARTIFACT_ID is gone. Not part of
# `all` (want() only matches step tokens 1/2/3), so the whole-act run stops
# with the hold in place; releasing is a deliberate, separate action.
if [ "$STEP" = "release" ]; then
echo "--- ACT 1 (cont.): clearing the hold, on the record ---"
_row=$(latest_team_pyyaml_row)
if [ -z "$_row" ]; then
  echo "No pyyaml artifact found in team-packages. Run step 3 first (bash acts/act1-gate.sh 3)."
  exit 1
fi
CVE_ARTIFACT_ID="${_row%%$'\t'*}"
_path="${_row#*$'\t'}"
CVE_WHEEL_NAME="${_path##*/}"
CVE_DOWNLOAD_URL="${AK_URL}/pypi/team-packages/simple/pyyaml/${CVE_WHEEL_NAME}"
echo "(artifact from step 3: ${CVE_WHEEL_NAME})"
echo
echo "Releasing the hold is not enough. The scan policy is an independent gate:"
echo "it keeps blocking while critical findings stand unacknowledged. Acknowledge"
echo "each finding, on the record, then release."
echo
echo "\$ (admin) listing scans for this artifact..."
SCAN_IDS=$(ak_api GET "/api/v1/security/artifacts/${CVE_ARTIFACT_ID}/scans" \
  | jq -r '(.items // .)[] | select(.status=="completed") | .id')
for id in $SCAN_IDS; do
  echo
  echo "\$ (admin) acknowledging critical/high findings on scan ${id}..."
  ak_api GET "/api/v1/security/scans/${id}/findings" \
    | jq -r '(.items // [])[] | select(.severity=="critical" or .severity=="high") | "\(.id)\t\(.cve_id)"' \
    | while IFS=$'\t' read -r finding_id cve_id; do
        [ -n "$finding_id" ] || continue
        ak_api POST "/api/v1/security/findings/${finding_id}/acknowledge" \
          '{"reason":"Risk accepted for the demo, on the record"}' >/dev/null
        echo "  acknowledged ${cve_id}"
      done
done
echo
echo "\$ (admin) releasing from quarantine..."
ak_api POST "/api/v1/quarantine/${CVE_ARTIFACT_ID}/release" '{}' | jq -c .
echo
echo "\$ curl -o /dev/null -w '%{http_code}\n' (download, post-release)"
curl -sS -o /dev/null -w '%{http_code}\n' "$CVE_DOWNLOAD_URL"
echo "EXPECTED: 200 -- both gates are now clear: the quarantine is released and"
echo "every critical/high finding was acknowledged first. Every step of that is"
echo "auditable: who acknowledged what, and when, plus the release itself."
fi

if [ "$STEP" = "all" ] || [ "$STEP" = "3" ]; then
  echo "ACT 1 COMPLETE: the gate held, twice."
fi

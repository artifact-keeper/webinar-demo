#!/usr/bin/env bash
# Act 2: but what about last month? Three numbered steps showing security
# posture applied after the fact, on artifacts that already exist: an
# on-demand rescan of a proxy-cached wheel nobody ever evaluated (plus the
# proxy SBOM and the serve-time block that follows it), a blast-radius query
# against a known CVE, and a quarantine-now lifecycle on a clean artifact.
#
# The rescan endpoint has a 30 second per-repository cooldown -- a second
# rescan against the same repo inside that window returns 429
# RESCAN_THROTTLED, so do not re-run step 1 back to back. Proxy scan state
# also persists once recorded: a re-run of step 1 against the same cached
# bytes starts from state "vulnerable", not "not_scanned". Getting a pristine
# not_scanned state again needs fresh volumes, or a different proxy-cached
# artifact picked up via the natural pip-download flow.
#
# Step 1 itself flips pypi-proxy's scan_configs row to scan_on_proxy=true
# (deliberately NOT done in setup/configure.sh: configure runs before
# warm-cache, and pre-enabling this would scan urllib3 at warm time,
# destroying the "cached before anyone looked" premise this act opens with).
# That flip is a live, on-record admin action, and it stays ON afterward --
# setup/reset.sh turns it back off as part of a full reset.
set -uo pipefail   # deliberately no -e: a 4xx/5xx response IS the demo
source "$(dirname "$0")/../setup/lib.sh"

[ -n "${PIP_INDEX_URL:-}" ] || { echo "Run this inside the JupyterLab terminal (see README)."; exit 1; }

PIP_INDEX="${PIP_INDEX_URL:-${AK_URL}/pypi/pypi-proxy/simple}"

DL=$(mktemp -d); trap 'rm -rf "$DL"' EXIT

# Run one step at a time, or all of them. `bash act2-lastmonth.sh 2` runs
# only step 2; no argument runs the whole act. Single-step mode is what the
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

# GET a URL and print its status line plus body -- but only when the body is
# small text/JSON. Guards a live demo against ever dumping a multi-MB binary
# artifact to the terminal if a probe unexpectedly succeeds.
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
echo "--- ACT 2.1: the cache remembers what nobody scanned ---"
echo "urllib3 1.24.1 came through this proxy before any policy existed. Nothing"
echo "ever evaluated it. Here is the registry's own record of that:"
echo
echo "\$ GET /api/v1/repositories/pypi-proxy/security/proxy-scans"
ak_api GET "/api/v1/repositories/pypi-proxy/security/proxy-scans" \
  | jq '{summary, items: [.items[] | {path, state, cached_at}]}'
# The sdist entry for pyyaml sits alongside urllib3 in this same cache, but a
# bare sdist tarball has no dist-info layout for the scanner's cataloger to
# read -- rescanning it comes back false-clean with zero packages. Only the
# wheel actually carries a package inventory the scanner can extract.
U3PATH=$(ak_api GET "/api/v1/repositories/pypi-proxy/security/proxy-scans" \
  | jq -r '.items[] | select(.path | test("urllib3.*\\.whl$")) | .path' | head -1)
if [ -z "$U3PATH" ]; then
  echo "No urllib3 wheel found in the pypi-proxy cache. Run setup/warm-cache.sh first (inside the Jupyter terminal)."
  exit 1
fi
echo
echo "\$ POST .../proxy-scans/rescan  {\"path\": \"${U3PATH}\"}"
ak_api POST "/api/v1/repositories/pypi-proxy/security/proxy-scans/rescan" \
  "{\"path\":\"${U3PATH}\"}" \
  | jq '{state, findings_count, max_severity, findings: [.findings[] | {cve_id, severity, package_name, fixed_version}]}'
echo
echo "EXPECTED: state flips to \"vulnerable\" with 12 findings, including"
echo "CVE-2019-11324, CVE-2019-11236, and CVE-2020-26137. The scan ran on the"
echo "CACHED bytes, on demand. No re-download, no pipeline."
echo
echo "\$ GET .../proxy-sbom?path=${U3PATH}&format=cyclonedx"
ak_api GET "/api/v1/repositories/pypi-proxy/security/proxy-sbom?path=${U3PATH}&format=cyclonedx" \
  | jq '{bomFormat, specVersion, components: [.components[] | {name, version, purl}]}'
echo
echo "EXPECTED: a CycloneDX SBOM generated from the cached artifact's recorded"
echo "package inventory. The proxy cache is not a blind spot anymore."
echo
echo "A rescan alone does not change what gets served -- it is a record, not"
echo "yet an enforcement action. Turning enforcement on for this proxy is:"
echo
echo "\$ PUT /api/v1/repositories/pypi-proxy/security  {\"scan_enabled\":true,\"scan_on_proxy\":true}"
ak_api PUT "/api/v1/repositories/pypi-proxy/security" \
  '{"scan_enabled":true,"scan_on_proxy":true}' | jq -c .
echo
echo "One call turns on scan-aware serving for this proxy. The verdict the"
echo "rescan just recorded now gates every download of these bytes:"
echo
echo "\$ curl -i ${PIP_INDEX}/urllib3/$(basename "$U3PATH")   (the same file, after the rescan)"
show_get "${PIP_INDEX}/urllib3/$(basename "$U3PATH")"
echo
echo "EXPECTED: HTTP 403, error code scan_blocked. The serve-time scan policy"
echo "now blocks this cached file for every consumer, immediately -- no"
echo "rebuild, no re-publish. The gate moved to the cache itself."
pause
fi

if want 2; then
echo "--- ACT 2.2: blast radius (the Tuesday-morning question) ---"
echo "\$ GET /api/v1/admin/security/cve/CVE-2020-14343/blast-radius"
ak_api GET "/api/v1/admin/security/cve/CVE-2020-14343/blast-radius" \
  | jq '{summary, proxy_exposure, affected_repos: [.affected_repos[] | {repository_key, access_scope}], downloaders: [.downloaders[] | {username, download_count, last_download}]}'
echo
echo "EXPECTED: 'downloaders' is your real, itemized who-pulled-it list --"
echo "artifact-keyed hosted downloads, attributable to a user or IP. Point at"
echo "that for 'who is actually exposed.' proxy_exposure is real too, not a"
echo "placeholder -- it's genuinely recorded (download_count above is a real"
echo "aggregate over every proxy pull of a digest carrying this CVE) -- but"
echo "it's tracked by content digest, not by artifact id, so it has no join"
echo "key back to a person or IP. Present it as 'how widely this is cached"
echo "and how many pulls, in aggregate,' never as a downloader list -- there"
echo "isn't one to show. Same summary+downloaders view in the UI:"
echo "  ${AK_WEB_URL}/security/blast-radius"
pause
fi

if want 3; then
echo "--- ACT 2.3: decide you do not trust it, right now ---"
echo "\$ pip download requests   (cache hit, clean artifact, no findings anywhere)"
REQ_DIR=$(freshdir)
pip download requests --no-deps -d "$REQ_DIR"
shopt -s nullglob
REQ_WHEEL_CANDIDATES=("$REQ_DIR"/requests-*.whl)
shopt -u nullglob
if [ ${#REQ_WHEEL_CANDIDATES[@]} -eq 0 ]; then
  echo "No requests wheel found in ${REQ_DIR} after pip download. Not continuing."
  exit 1
fi
REQ_WHEEL="${REQ_WHEEL_CANDIDATES[0]}"
REQ_VERSION=$(basename "$REQ_WHEEL" | sed -E 's/^requests-([0-9][^-]*)-.*/\1/')
# Same reason as Act 1's CVE_RUN_TAG: a random PEP 427 build-tag segment so
# every run publishes to a never-before-used path in team-packages. Without
# it, re-publishing the exact same path+digest after deleting it resurrects
# the old artifact row (team-packages' delete is a soft-delete) instead of
# starting clean.
REQ_RUN_TAG="$RANDOM"
REQ_UPLOAD_NAME="requests-${REQ_VERSION}-1${REQ_RUN_TAG}-py3-none-any.whl"
REQ_UPLOAD_FILE="$DL/${REQ_UPLOAD_NAME}"
cp "$REQ_WHEEL" "$REQ_UPLOAD_FILE"
REQ_SHA256=$(shasum -a 256 "$REQ_UPLOAD_FILE" | awk '{print $1}')
echo
echo "\$ (admin) publishing requests ${REQ_VERSION} to the internal team-packages repo..."
curl -sS -u "${AK_ADMIN_USER}:${AK_ADMIN_PASSWORD}" \
  -F ":action=file_upload" -F "name=requests" -F "version=${REQ_VERSION}" \
  -F "sha256_digest=${REQ_SHA256}" \
  -F "content=@${REQ_UPLOAD_FILE};type=application/octet-stream" \
  "${AK_URL}/pypi/team-packages/" >/dev/null

_row=$(ak_api GET /api/v1/repositories/team-packages/artifacts \
  | jq -r --arg f "$REQ_UPLOAD_NAME" '(.items // .)[] | select(.path | contains($f)) | "\(.id)\t\(.path)"' | head -1)
AID="${_row%%$'\t'*}"
REQ_ARTIFACT_PATH="${_row#*$'\t'}"
echo "artifact_id=${AID:-<not found>}"
if [ -z "${AID:-}" ] || [ "$AID" = "null" ]; then
  echo "Could not find the artifact just published (path containing ${REQ_UPLOAD_NAME}) in team-packages. Not continuing: quarantining a missing artifact id would silently do nothing."
  exit 1
fi
DOWNLOAD_URL="${AK_URL}/pypi/team-packages/simple/requests/${REQ_UPLOAD_NAME}"

echo
echo "\$ curl -o /dev/null -w '%{http_code}\n' (download, unscanned)"
curl -sS -o /dev/null -w '%{http_code}\n' "$DOWNLOAD_URL"
echo "EXPECTED: 200 -- nobody has scanned this artifact, and the scan policy"
echo "does not block an unscanned artifact. This is not a CVE story."
echo
echo "\$ (admin) quarantining it anyway -- an incident review says hold it, no"
echo "scan finding required:"
echo "\$ POST /api/v1/quarantine/${AID}/quarantine"
ak_api POST "/api/v1/quarantine/${AID}/quarantine" \
  '{"reason":"Held pending incident review, ref INC-2041"}' | jq -c .
echo
echo "\$ curl -i (download, post admin-hold)"
show_get "$DOWNLOAD_URL"
echo
echo "EXPECTED: HTTP 409 with a generic body (\"Artifact is quarantined...\")."
echo "It does not echo the reason back -- that lives on the record, not the"
echo "409 itself:"
echo
echo "\$ GET /api/v1/quarantine/${AID}"
ak_api GET "/api/v1/quarantine/${AID}" | jq .
echo
echo "EXPECTED: the admin's exact reason text, on the record above, and in the"
echo "audit log. The 409 blocks the download; the record and the log carry why."
echo
echo "\$ (admin) releasing..."
ak_api POST "/api/v1/quarantine/${AID}/release" '{}' | jq -c .
echo
echo "\$ curl -o /dev/null -w '%{http_code}\n' (download, post-release)"
curl -sS -o /dev/null -w '%{http_code}\n' "$DOWNLOAD_URL"
echo "EXPECTED: 200 -- no findings on this artifact, so release alone restores"
echo "service. Contrast with Act 1's pyyaml artifact, where release alone was"
echo "not enough: the scan policy kept blocking until every critical/high"
echo "finding was also acknowledged."
echo
echo "\$ (admin) cleaning up..."
AK_API_ALLOW_FAIL=1 ak_api DELETE "/api/v1/repositories/team-packages/artifacts/${REQ_ARTIFACT_PATH}" >/dev/null
echo "deleted"
echo
echo "Every action just taken -- publish, quarantine, release, delete -- is in"
echo "the audit log:"
echo "  ${AK_WEB_URL}/audit"
fi

if [ "$STEP" = "all" ] || [ "$STEP" = "3" ]; then
  echo "ACT 2 COMPLETE: last month is covered too."
fi

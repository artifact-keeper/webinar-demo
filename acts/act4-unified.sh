#!/usr/bin/env bash
# Act 4: one door, not two. A virtual repository (`pypi-unified`) fronts both
# `pypi-proxy` (remote, priority 10) and `team-packages` (local, priority 0).
# PEP 708 isolation means a package name the local member owns is hidden from
# the merged index for any remote member configured at a WORSE priority --
# so once a package is published and released locally, the proxy's copy of
# the same name stops mattering entirely, even if the proxy would otherwise
# block it. This act shows the "before": blocked, and the "after": released,
# live, back to back, through the ONE index consumers actually use.
#
# Uses urllib3==1.25.8 specifically because it is NOT the version any other
# act touches (1.24.1 is Act 2's rescan target). Reusing identical content
# that has already been scanned elsewhere hits a real content-dedup bug
# where the findings surfaced via GET /security/scans/{id}/findings belong
# to the ORIGINAL scan, not the one gating THIS artifact's download --
# acknowledging them silently acknowledges the wrong rows. A fresh version
# means a fresh scan, so this act does not depend on that bug being fixed.
set -uo pipefail   # deliberately no -e: a 4xx/5xx response IS the demo
source "$(dirname "$0")/../setup/lib.sh"

[ -n "${PIP_INDEX_URL:-}" ] || { echo "Run this inside the JupyterLab terminal (see README)."; exit 1; }

UNIFIED_INDEX="${AK_URL}/pypi/pypi-unified/simple"
PKG_VERSION="1.25.8"
WHEEL_NAME="urllib3-${PKG_VERSION}-py2.py3-none-any.whl"

STEP="${STEP:-${1:-all}}"
want() { [ "$STEP" = "all" ] || [ "$STEP" = "$1" ]; }

if want 1 || [ "$STEP" = "all" ]; then
echo "--- ACT 4.1: one index, publish locally, watch it stay blocked ---"
ak_login || exit 1

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
echo
echo "\$ (fetching the real wheel directly from PyPI -- not through our own"
echo "   proxy, which would legitimately cache-miss and is not the point here)"
curl -sL -o "$TMP/${WHEEL_NAME}" \
  "$(curl -s "https://pypi.org/pypi/urllib3/${PKG_VERSION}/json" | jq -r '.urls[] | select(.packagetype=="bdist_wheel") | .url')"

RUN_TAG="$RANDOM"
UPLOAD_NAME="urllib3-${PKG_VERSION}-1${RUN_TAG}-py2.py3-none-any.whl"
echo
echo "\$ (admin) publishing urllib3 ${PKG_VERSION} to team-packages..."
curl -sS -X POST "${AK_URL}/pypi/team-packages/" \
  -H "Authorization: Bearer ${AK_TOKEN}" \
  -F ":action=file_upload" -F "name=urllib3" -F "version=${PKG_VERSION}" \
  -F "filetype=bdist_wheel" -F "pyversion=py2.py3" \
  -F "content=@${TMP}/${WHEEL_NAME};filename=${UPLOAD_NAME}" >/dev/null

AID=$(ak_api GET "/api/v1/repositories/team-packages/artifacts" \
  | jq -r --arg n "$UPLOAD_NAME" '(.items // .)[] | select(.path | endswith($n)) | .id')
echo "$AID" > "$(dirname "$0")/../tmp/act4-artifact-id"
echo "(artifact_id: ${AID})"

echo
echo "\$ (admin) scanning..."
ak_api POST /api/v1/security/scan "{\"artifact_id\":\"${AID}\"}" >/dev/null
for i in $(seq 1 30); do
  status=$(ak_api GET "/api/v1/security/artifacts/${AID}/scans" \
    | jq -r '(.items // [])[] | select(.scan_type=="grype") | .status')
  [ "$status" = "completed" ] && break
  sleep 2
done
FINDINGS=$(ak_api GET "/api/v1/security/artifacts/${AID}/scans" \
  | jq -r '(.items // [])[] | select(.scan_type=="grype") | .findings_count')
echo "grype: ${FINDINGS} findings -- auto-quarantined the moment the scan completed."

echo
echo "\$ pip download urllib3==${PKG_VERSION}   (through pypi-unified -- ONE index, local + proxy)"
PIP_INDEX_URL="$UNIFIED_INDEX" pip download "urllib3==${PKG_VERSION}" --no-deps -d "$TMP/dl-before" 2>&1 | tail -6
echo
echo "EXPECTED: a real fetch error, not a plain 'no matching version'. The"
echo "local copy is the one and only entry for this name in the merged index"
echo "(the proxy's copy is isolated away by priority) -- but it is quarantined,"
echo "so pip finds it, tries to fetch it, and gets refused."
fi

if [ "$STEP" = "release" ]; then
echo "--- ACT 4 (cont.): release it, on the record, then ask again ---"
ak_login || exit 1
AID=$(cat "$(dirname "$0")/../tmp/act4-artifact-id" 2>/dev/null)
if [ -z "$AID" ]; then
  echo "No Act 4 artifact on record. Run step 1 first (bash acts/act4-unified.sh 1)."
  exit 1
fi

SCAN_ID=$(ak_api GET "/api/v1/security/artifacts/${AID}/scans" \
  | jq -r '(.items // [])[] | select(.scan_type=="grype") | .id')
echo
echo "\$ (admin) acknowledging every critical/high finding..."
ak_api GET "/api/v1/security/scans/${SCAN_ID}/findings" \
  | jq -r '(.items // [])[] | select(.severity=="critical" or .severity=="high") | "\(.id)\t\(.cve_id)"' \
  | while IFS=$'\t' read -r finding_id cve_id; do
      [ -n "$finding_id" ] || continue
      ak_api POST "/api/v1/security/findings/${finding_id}/acknowledge" \
        '{"reason":"Risk accepted for the demo, on the record"}' >/dev/null
      echo "  acknowledged ${cve_id}"
    done

echo
echo "\$ (admin) releasing from quarantine..."
ak_api POST "/api/v1/quarantine/${AID}/release" '{}' | jq -c .

echo
TMP2=$(mktemp -d); trap 'rm -rf "$TMP2"' EXIT
echo "\$ pip download urllib3==${PKG_VERSION}   (same command, same index, nothing else changed)"
PIP_INDEX_URL="$UNIFIED_INDEX" pip download "urllib3==${PKG_VERSION}" --no-deps -d "$TMP2" 2>&1 | tail -6
echo
echo "EXPECTED: downloads clean. The proxy never had a say in this -- it's"
echo "still just as blocked as before -- because the local copy shadows it"
echo "in the index the moment local owns the name."
fi

if [ "$STEP" = "all" ]; then
  echo "ACT 4 COMPLETE (before the release beat). Run: bash acts/act4-unified.sh release"
fi

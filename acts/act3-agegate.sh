#!/usr/bin/env bash
# Act 3: do not be there next time. Two numbered steps showing the age
# gate configured on pypi-proxy (Task 3): a package released inside the
# 14-day cooling-off window is invisible to pip and returns 451 with a
# pending review on direct fetch, then the same fetch returns 200 once a
# human approves that review, on the record.
#
# Two operational facts about the gate on this stack: approval is permanent
# per package+version for the life of the stack (setup/reset.sh clears the
# review table, so a reset+configure cycle restores the 451 for a fresh
# request); and the API fallback for approval, when the UI is not at hand,
# is `ak_api POST /api/v1/admin/age-gate/reviews/<id>/approve '{}'`.
set -uo pipefail   # deliberately no -e: a 4xx/5xx response IS the demo
source "$(dirname "$0")/../setup/lib.sh"

PIP_INDEX="${PIP_INDEX_URL:-${AK_URL}/pypi/pypi-proxy/simple}"

DL=$(mktemp -d); trap 'rm -rf "$DL"' EXIT

# Run one step at a time, or all of them. `bash act3-agegate.sh 2` runs
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

# The package defaults to the latest boto3 release: boto3 ships near-daily,
# so the latest release is almost always still inside the 14-day window.
# AGE_GATE_PKG=name==version overrides.
if [ -z "${AGE_GATE_PKG:-}" ]; then
  _v=$(curl -fsS https://pypi.org/pypi/boto3/json | jq -r .info.version)
  AGE_GATE_PKG="boto3==${_v}"
fi
AGE_GATE_NAME="${AGE_GATE_PKG%%==*}"; AGE_GATE_VERSION="${AGE_GATE_PKG##*==}"
AGE_GATE_WHEEL=$(curl -fsS "https://pypi.org/pypi/${AGE_GATE_NAME}/${AGE_GATE_VERSION}/json" \
  | jq -r '.urls[] | select(.packagetype=="bdist_wheel") | .filename' | head -1)

if want 1; then
echo "--- ACT 3.1: the first wave is not for you ---"
echo "\$ pip install ${AGE_GATE_PKG}   (released in the last 14 days)"
pip download "${AGE_GATE_PKG}" --index-url "$PIP_INDEX" --no-deps -d "$(freshdir)"
echo
echo "The version is missing from the index entirely; pip cannot even see it."
echo "Hitting the file directly shows the real gate:"
echo
echo "\$ curl -i ${PIP_INDEX}/${AGE_GATE_NAME}/${AGE_GATE_WHEEL}"
show_get "${PIP_INDEX}/${AGE_GATE_NAME}/${AGE_GATE_WHEEL}"
echo
echo "EXPECTED: HTTP 451, body error age_gate_blocked, min_age_days 14, plus a"
echo "review_id, package, and version. A 14-day cooling-off window:"
echo "xz-utils-class compromises get caught in days, and this gate means your"
echo "builds were never in the first wave. Approve it, on the record, at:"
echo "  ${AK_WEB_URL}/age-gate"
echo "then run:  bash acts/act3-agegate.sh 2"
pause
fi

if want 2; then
echo "--- ACT 3.2: a human said yes ---"
echo "\$ curl -i ${PIP_INDEX}/${AGE_GATE_NAME}/${AGE_GATE_WHEEL}   (post-approval)"
show_get "${PIP_INDEX}/${AGE_GATE_NAME}/${AGE_GATE_WHEEL}"
echo
echo "EXPECTED: HTTP 200. The approval is auditable, per version, permanent."
echo "ACT 3 COMPLETE: next time, you are two weeks behind the blast."
fi

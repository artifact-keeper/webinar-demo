#!/usr/bin/env bash
# Friendly alias for `preflight.sh`, which already does everything "start"
# implies: pulls images, builds the Jupyter container, brings the stack up,
# waits for the backend to report healthy, waits for the seed to finish, and
# prints the three URLs. Kept as a separate file (not a rename) so existing
# references to preflight.sh in README.md/RUNBOOK.md keep working, and so
# `setup/{start,stop,reset}.sh` reads as one matched set at a glance.
set -euo pipefail
exec "$(dirname "$0")/preflight.sh" "$@"

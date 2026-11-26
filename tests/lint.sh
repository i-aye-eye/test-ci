#!/bin/bash
# Runs shellcheck on every script, actionlint on the workflows, and the profile and
# event checks.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
shellcheck -x -P SCRIPTDIR tests/*.sh examples/ci/*.sh
if command -v actionlint >/dev/null; then
  actionlint .github/workflows/*.yml
else
  echo "actionlint not installed: skipped"
fi
tests/check-profiles.sh
tests/check-events.sh

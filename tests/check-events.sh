#!/bin/bash
# gh200.yml's two jobs, request and run, must allow the same events: push,
# pull_request, workflow_dispatch and schedule, the job API's list. Not
# pull_request_target, issue_comment or anything else someone outside the repo can start.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
want='contains(fromJSON('"'"'["push","pull_request","workflow_dispatch","schedule"]'"'"'), github.event_name)'
found=$(grep -cF -- "$want" "$root/.github/workflows/gh200.yml" || true)
if [ "$found" != 2 ]; then
  echo "gh200.yml: expected the event list in both jobs (request, run), found it $found times" >&2
  exit 1
fi
for event in pull_request_target issue_comment workflow_run; do
  if grep -qF "\"$event\"" "$root/.github/workflows/gh200.yml"; then
    echo "gh200.yml: $event mustn't be allowed" >&2
    exit 1
  fi
done
echo "ok   gh200.yml's jobs allow only push, pull_request, workflow_dispatch and schedule"

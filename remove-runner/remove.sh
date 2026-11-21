#!/bin/bash
# remove.sh: the remove-runner action's step, on GitHub's own runner, after the job.
#
# Removes the runner request-runner made for the job, unless it's gone already (a
# runner that takes its job removes itself when the job ends) or it's running a job.
# Left alone, an unused one stays registered, offline, until GitHub removes it after
# about a day. Only warns if it can't: removing it isn't worth failing the run for.
set -uo pipefail

[ -n "${RUNNER_ID:-}" ] || { echo "No runner to remove"; exit 0; }
[[ $RUNNER_ID =~ ^[0-9]+$ ]] || { echo "::warning::Not a runner ID: $RUNNER_ID"; exit 0; }
: "${REPO:?}"

if ! busy=$(gh api "repos/$REPO/actions/runners/$RUNNER_ID" --jq .busy 2>&1); then
  case $busy in
    *"HTTP 404"*) echo "Runner $RUNNER_ID has gone already: its job used it, or it was removed" ;;
    *) echo "::warning::Couldn't look up runner $RUNNER_ID, so it may stay registered: $busy" ;;
  esac
  exit 0
fi
if [ "$busy" = true ]; then
  echo "Runner $RUNNER_ID is running a job: leaving it"
  exit 0
fi
if out=$(gh api -X DELETE "repos/$REPO/actions/runners/$RUNNER_ID" 2>&1); then
  echo "Removed runner $RUNNER_ID: no job used it"
else
  echo "::warning::Couldn't remove runner $RUNNER_ID: $out"
fi
exit 0

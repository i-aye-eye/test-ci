#!/bin/bash
# Runs request-runner's request.sh (dispatch: mvp) against stand-ins for gh, GitHub's
# OIDC token service and the job API: the job script it sends, the tokens it sends
# with it, the release link it reports, and its refusals; that it asks the job API
# before making a runner config, and removes the config if the job still isn't added.
# No network. The runner side is tested in test-ci-runner.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL - $*" >&2; exit 1; }
export FAKE_OUT=$t

mkdir -p "$t/stub"
cat > "$t/stub/curl" <<'EOF'
#!/bin/bash
# GitHub's OIDC token service
case "$*" in *token.example*)
  printf '%s\n' "$@" > "$FAKE_OUT/oidc-args"
  echo '{"count": 1, "value": "eyJhbGciOi.eyJpc3Mi.c2lnbmF0dXJl"}'
  exit 0 ;;
esac
# The job API: -o FILE gets the reply, and -w prints the HTTP code. /jobs/check
# answers FAKE_CHECK_CODE (204), and POST /jobs FAKE_CODE (201)
case "$*" in *ci.example/jobs/check*)
  printf '%s\n' "$@" > "$FAKE_OUT/check-args"
  echo check >> "$FAKE_OUT/calls"
  while [ $# -gt 0 ]; do [ "$1" = -o ] && { out=$2; break; }; shift; done
  [ "${FAKE_CHECK_CODE:-204}" = 000 ] && { echo "curl: (7) Failed to connect" >&2; exit 7; }
  printf '%s' "${FAKE_CHECK_REPLY:-}" > "$out"
  printf '%s' "${FAKE_CHECK_CODE:-204}"
  exit 0 ;;
esac
printf '%s\n' "$@" > "$FAKE_OUT/curl-args"
echo jobs >> "$FAKE_OUT/calls"
out=""
while [ $# -gt 0 ]; do
  case $1 in
    -o) out=$2; shift 2 ;;
    @*) cp "${1#@}" "$FAKE_OUT/job.sh"; shift ;;
    *) shift ;;
  esac
done
[ "${FAKE_CODE:-201}" = 000 ] && { echo "curl: (7) Failed to connect" >&2; exit 7; }
printf '%s' "${FAKE_REPLY:-{\"id\": \"dQw4w9WgXcQ\", \"release_url\": \"https://ci.example/ci/job?id=dQw4w9WgXcQ\"\}}" > "$out"
printf '%s' "${FAKE_CODE:-201}"
EOF
cat > "$t/stub/gh" <<'EOF'
#!/bin/bash
# Deleting a runner: recorded, and fails if FAKE_DELETE_FAILS is set
if [ "$1 $2" = "api -X" ] && [ "$3" = DELETE ]; then
  echo "$4" >> "$FAKE_OUT/gh-delete"
  echo delete >> "$FAKE_OUT/calls"
  [ -z "${FAKE_DELETE_FAILS:-}" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
  exit 0
fi
# Making a runner config: what gh prints after request.sh's --jq, config then runner ID
printf '%s\n' "$@" > "$FAKE_OUT/gh-args"
echo jitconfig >> "$FAKE_OUT/calls"
echo "${FAKE_JIT-QUJDREVG 42}"
EOF
chmod +x "$t/stub/curl" "$t/stub/gh"
launcher=/opt/test-ci-runner/launcher/launch-runner.sh

request() {   # request <profile> <run id> [<dispatch>]
  : > "$t/summary"; : > "$t/output"
  rm -f "$t/oidc-args" "$t/curl-args" "$t/check-args" "$t/gh-args" "$t/gh-delete" "$t/calls"
  PATH="$t/stub:$PATH" DISPATCH=${3:-mvp} PROFILE=$1 ORIGIN_TOKEN=ot GH_TOKEN=pat \
    URL=https://ci.example/ LAUNCHER=$launcher REPO=o/r RUN_ID=$2 RUN_ATTEMPT=1 \
    GITHUB_STEP_SUMMARY=$t/summary GITHUB_OUTPUT=$t/output \
    "$root/request-runner/request.sh" > "$t/log" 2>&1
}
# GitHub sets these when the workflow grants id-token: write
with_oidc() {
  ACTIONS_ID_TOKEN_REQUEST_URL='https://token.example/req?api-version=2.0' \
    ACTIONS_ID_TOKEN_REQUEST_TOKEN=rt "$@"
}

request gh200-1gpu 88 || fail "request.sh: $(cat "$t/log")"
grep -qx '#SBATCH --gpus=1' "$t/job.sh" || fail "job script: $(cat "$t/job.sh")"
grep -qx "export ACTIONS_RUNNER_INPUT_JITCONFIG='QUJDREVG'" "$t/job.sh" || fail "config in job script"
grep -qx "exec $launcher --profile gh200-1gpu --runner-minutes 55 --config-env --expect-repo o/r --expect-run 88" \
  "$t/job.sh" || fail "launcher line: $(tail -1 "$t/job.sh")"
grep -qxF 'labels[]=test-ci-gh200-1gpu' "$t/gh-args" || fail "profile label: $(cat "$t/gh-args")"
grep -qxF 'labels[]=test-ci-run-88' "$t/gh-args" || fail "run label: $(cat "$t/gh-args")"
grep -qx 'https://ci.example/jobs' "$t/curl-args" || fail "job API URL"
grep -q 'release-url=https://ci.example/ci/job?id=dQw4w9WgXcQ' "$t/output" || fail "output: $(cat "$t/output")"
# shellcheck disable=SC2016  # the backticks are the summary's own, not a command
grep -qF '`https://ci.example/ci/job?id=dQw4w9WgXcQ`' "$t/summary" || fail "summary: $(cat "$t/summary")"
grep -q 'job dQw4w9WgXcQ' "$t/summary" || fail "job ID in summary"
! grep -q 'Task token' "$t/log" || fail "printed a task token: $(cat "$t/log")"
bash -n "$t/job.sh" || fail "job script isn't valid bash"
echo "ok - mvp: job script, runner minutes, labels, job API call, release link"

# Asks first, then makes the config, then adds the job; keeps the runner's ID
[ "$(paste -sd' ' "$t/calls")" = "check jitconfig jobs" ] || fail "order: $(paste -sd' ' "$t/calls")"
grep -qx 'https://ci.example/jobs/check' "$t/check-args" || fail "check URL: $(cat "$t/check-args")"
! grep -q -- '--data-binary' "$t/check-args" || fail "the check sent a body"
grep -qx 'runner-id=42' "$t/output" || fail "runner-id output: $(cat "$t/output")"
[ ! -e "$t/gh-delete" ] || fail "removed the runner of a job that was added"
echo "ok - mvp: asks the job API first, then makes the config, keeps the runner ID"

# Without id-token: write, the origin token alone, as before
grep -qx 'Authorization: Bearer ot' "$t/curl-args" || fail "origin token: $(cat "$t/curl-args")"
! grep -q 'Origin-Token' "$t/curl-args" || fail "sent Origin-Token without a GitHub token"
[ ! -e "$t/oidc-args" ] || fail "asked for a GitHub token without the permission"
grep -q "::notice::No GitHub OIDC token" "$t/log" || fail "no notice: $(cat "$t/log")"
echo "ok - mvp: without id-token: write, the origin token alone, with a notice"

# With id-token: write, GitHub's token as the bearer token, the origin token beside it
with_oidc request gh200-1gpu 90 || fail "request.sh with OIDC: $(cat "$t/log")"
grep -qx 'https://token.example/req?api-version=2.0&audience=isambard-ci' "$t/oidc-args" \
  || fail "token request: $(cat "$t/oidc-args")"
grep -qx 'Authorization: Bearer rt' "$t/oidc-args" || fail "token request's own token"
grep -qx 'Authorization: Bearer eyJhbGciOi.eyJpc3Mi.c2lnbmF0dXJl' "$t/curl-args" || fail "GitHub token: $(cat "$t/curl-args")"
grep -qx 'Origin-Token: ot' "$t/curl-args" || fail "Origin-Token: $(cat "$t/curl-args")"
! grep -qx 'Authorization: Bearer ot' "$t/curl-args" || fail "origin token sent as the bearer token too"
grep -qx '::add-mask::eyJhbGciOi.eyJpc3Mi.c2lnbmF0dXJl' "$t/log" || fail "GitHub token not masked"
grep -qx 'Authorization: Bearer eyJhbGciOi.eyJpc3Mi.c2lnbmF0dXJl' "$t/check-args" \
  || fail "the check's GitHub token: $(cat "$t/check-args")"
grep -qx 'Origin-Token: ot' "$t/check-args" || fail "the check's Origin-Token"
[ "$(grep -c 'token.example' "$t/oidc-args")" = 1 ] || fail "asked GitHub for more than one token"
echo "ok - mvp: with id-token: write, GitHub's token (masked) and the origin token, for both calls"

# An older job API's reply: the task token is printed for the release
FAKE_REPLY='{"job_id": 12, "task_token": "tt", "release_url": "https://ci.example/ci/"}' \
  request gh200-1gpu 91 || fail "request.sh, old reply: $(cat "$t/log")"
grep -qx 'Task token: tt' "$t/log" || fail "old reply: no task token: $(cat "$t/log")"
grep -q 'job 12' "$t/summary" || fail "old reply summary: $(cat "$t/summary")"
grep -q 'task token' "$t/summary" || fail "old reply summary: $(cat "$t/summary")"
echo "ok - mvp: an older job API's reply still works"

# The job API's answers, told apart
FAKE_CODE=000 request gh200-1gpu 92 && fail "unreachable job API accepted"
grep -q "Couldn't reach the job API at https://ci.example/" "$t/log" || fail "unreachable: $(cat "$t/log")"
grep -qx 'repos/o/r/actions/runners/42' "$t/gh-delete" || fail "didn't remove the runner: $(cat "$t/log")"
FAKE_CODE=401 FAKE_REPLY='{"detail": "Missing or invalid origin token"}' request gh200-1gpu 93 && fail "401 accepted"
grep -q 'refused the request (HTTP 401): Missing or invalid origin token' "$t/log" || fail "401: $(cat "$t/log")"
FAKE_CODE=530 FAKE_REPLY='error code: 1033' request gh200-1gpu 94 && fail "530 accepted"
grep -q 'answered HTTP 530. Is it, or its tunnel, up?' "$t/log" || fail "530: $(cat "$t/log")"
echo "ok - mvp: tells an unreachable job API (or tunnel) from a refusal"

# Refused when asked first: no runner config is made, and nothing is added
FAKE_CHECK_CODE=403 FAKE_CHECK_REPLY='{"detail": "o/r isn'"'"'t registered with the CI service"}' \
  with_oidc request gh200-1gpu 96 && fail "a refused check went on"
grep -q "refused the request (HTTP 403): o/r isn't registered with the CI service" "$t/log" \
  || fail "refused check: $(cat "$t/log")"
[ "$(paste -sd' ' "$t/calls")" = check ] || fail "made a config after a refusal: $(paste -sd' ' "$t/calls")"
FAKE_CHECK_CODE=401 FAKE_CHECK_REPLY='{"detail": "Missing or invalid origin token"}' \
  request gh200-1gpu 97 && fail "a 401 check went on"
[ "$(paste -sd' ' "$t/calls")" = check ] || fail "made a config after a 401: $(paste -sd' ' "$t/calls")"
FAKE_CHECK_CODE=000 request gh200-1gpu 98 && fail "an unreachable check went on"
grep -q "Couldn't reach the job API at https://ci.example/" "$t/log" || fail "unreachable check: $(cat "$t/log")"
[ "$(paste -sd' ' "$t/calls")" = check ] || fail "made a config with no job API: $(paste -sd' ' "$t/calls")"
echo "ok - mvp: refused or unreachable when asked first, so no runner config is made"

# Refused after all, when adding the job: the runner made for it is removed
FAKE_CODE=403 FAKE_REPLY='{"detail": "o/r isn'"'"'t registered with the CI service"}' \
  request gh200-1gpu 99 && fail "a refused job was accepted"
[ "$(paste -sd' ' "$t/calls")" = "check jitconfig jobs delete" ] || fail "order: $(paste -sd' ' "$t/calls")"
grep -qx 'repos/o/r/actions/runners/42' "$t/gh-delete" || fail "removed: $(cat "$t/gh-delete")"
grep -q 'Removed runner 42' "$t/log" || fail "no message: $(cat "$t/log")"
FAKE_CODE=403 FAKE_DELETE_FAILS=1 request gh200-1gpu 100 && fail "a refused job was accepted"
grep -q "::warning::Couldn't remove runner 42" "$t/log" || fail "no warning: $(cat "$t/log")"
echo "ok - mvp: refused when adding the job, so the runner made for it is removed"

# An older job API without /jobs/check: a notice, then on as before
FAKE_CHECK_CODE=404 request gh200-1gpu 101 || fail "an older job API: $(cat "$t/log")"
grep -q "::notice::This job API can't be asked first" "$t/log" || fail "no notice: $(cat "$t/log")"
[ "$(paste -sd' ' "$t/calls")" = "check jitconfig jobs" ] || fail "order: $(paste -sd' ' "$t/calls")"
echo "ok - mvp: an older job API without /jobs/check still works"

# GitHub's reply without a runner ID: a warning, and nothing to remove later
FAKE_JIT=QUJDREVG request gh200-1gpu 102 || fail "no runner ID: $(cat "$t/log")"
grep -q "::warning::GitHub didn't say which runner" "$t/log" || fail "no warning: $(cat "$t/log")"
! grep -q 'runner-id=' "$t/output" || fail "runner-id output without an ID"
FAKE_JIT=QUJDREVG FAKE_CODE=403 request gh200-1gpu 103 && fail "a refused job was accepted"
[ ! -e "$t/gh-delete" ] || fail "tried to remove a runner with no ID"
echo "ok - mvp: GitHub's reply without a runner ID"

request dev-cpu 89 || fail "request.sh dev-cpu: $(cat "$t/log")"
! grep -q -- '--gpus' "$t/job.sh" || fail "dev-cpu job script asks for GPUs: $(cat "$t/job.sh")"
grep -qx '#SBATCH --time=00:30:00' "$t/job.sh" || fail "dev-cpu job script: $(cat "$t/job.sh")"
echo "ok - mvp: dev-cpu asks for no GPU"

# Which launcher: the input if given, else the profile's, else the dev stack's. A copy
# of request-runner, with a profile that names its own launcher
cp -r "$root/request-runner" "$t/rr"
jq '.["gh200-1gpu"].launcher = "/shared/ci/test-ci-runner/launcher/launch-runner.sh"' \
  "$root/request-runner/profiles.json" > "$t/rr/profiles.json"
from_copy() {   # from_copy <launcher input> <profile>
  PATH="$t/stub:$PATH" DISPATCH=mvp PROFILE=$2 ORIGIN_TOKEN=ot GH_TOKEN=pat \
    URL=https://ci.example/ LAUNCHER=$1 REPO=o/r RUN_ID=95 RUN_ATTEMPT=1 \
    GITHUB_STEP_SUMMARY=$t/summary GITHUB_OUTPUT=$t/output \
    "$t/rr/request.sh" > "$t/log" 2>&1 || fail "request.sh: $(cat "$t/log")"
  tail -1 "$t/job.sh" | cut -d' ' -f2
}
[ "$(from_copy "" gh200-1gpu)" = /shared/ci/test-ci-runner/launcher/launch-runner.sh ] \
  || fail "the profile's launcher: $(tail -1 "$t/job.sh")"
[ "$(from_copy "" gh200-4gpu)" = /opt/test-ci-runner/launcher/launch-runner.sh ] \
  || fail "the default launcher: $(tail -1 "$t/job.sh")"
[ "$(from_copy /mine/launch-runner.sh gh200-1gpu)" = /mine/launch-runner.sh ] \
  || fail "the launcher input: $(tail -1 "$t/job.sh")"
echo "ok - mvp: the launcher input, else the profile's, else the dev stack's"

if request gh200-1gpu 1 service; then fail "service should fail for now"; fi
if request no-such-profile 1; then fail "an unknown profile should fail"; fi
echo "ok - refuses dispatch: service (not built) and unknown profiles"

#!/bin/bash
# Runs remove-runner's remove.sh against a stand-in for gh: it removes the runner only
# if it's still registered and not running a job, and never fails the run. No network.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL - $*" >&2; exit 1; }
export FAKE_OUT=$t

mkdir -p "$t/stub"
cat > "$t/stub/gh" <<'STUB'
#!/bin/bash
# Looking the runner up answers FAKE_BUSY (false, true, 404 or 401); deleting it is
# recorded, and fails if FAKE_DELETE_FAILS is set
if [ "$2" = -X ] && [ "$3" = DELETE ]; then
  echo "$4" >> "$FAKE_OUT/deleted"
  [ -z "${FAKE_DELETE_FAILS:-}" ] || { echo "gh: Server Error (HTTP 500)"; exit 1; }
  exit 0
fi
echo "$2" >> "$FAKE_OUT/looked-up"
case ${FAKE_BUSY:-false} in
  404) echo "gh: Not Found (HTTP 404)"; exit 1 ;;
  401) echo "gh: Bad credentials (HTTP 401)"; exit 1 ;;
  *) echo "$FAKE_BUSY" ;;
esac
STUB
chmod +x "$t/stub/gh"

remove() {   # remove <runner id>: must always succeed
  rm -f "$t/deleted" "$t/looked-up"
  PATH="$t/stub:$PATH" GH_TOKEN=pat REPO=o/r RUNNER_ID=$1 \
    "$root/remove-runner/remove.sh" > "$t/log" 2>&1 || fail "remove.sh failed: $(cat "$t/log")"
}

FAKE_BUSY=false remove 42
grep -qx 'repos/o/r/actions/runners/42' "$t/looked-up" || fail "looked up: $(cat "$t/looked-up")"
grep -qx 'repos/o/r/actions/runners/42' "$t/deleted" || fail "not removed: $(cat "$t/log")"
grep -q 'Removed runner 42: no job used it' "$t/log" || fail "message: $(cat "$t/log")"
echo "ok - removes a runner no job used"

FAKE_BUSY=404 remove 42
[ ! -e "$t/deleted" ] || fail "removed a runner that had gone"
grep -q 'Runner 42 has gone already' "$t/log" || fail "message: $(cat "$t/log")"
echo "ok - leaves a runner that has gone already, as after its job"

FAKE_BUSY=true remove 42
[ ! -e "$t/deleted" ] || fail "removed a busy runner"
grep -q 'running a job: leaving it' "$t/log" || fail "message: $(cat "$t/log")"
echo "ok - leaves a runner that's running a job"

FAKE_BUSY=401 remove 42
[ ! -e "$t/deleted" ] || fail "removed a runner it couldn't look up"
grep -q "::warning::Couldn't look up runner 42" "$t/log" || fail "warning: $(cat "$t/log")"
FAKE_BUSY=false FAKE_DELETE_FAILS=1 remove 42
grep -q "::warning::Couldn't remove runner 42" "$t/log" || fail "warning: $(cat "$t/log")"
echo "ok - only warns if it can't look the runner up or remove it"

remove ""
[ ! -e "$t/looked-up" ] || fail "looked up a runner with no ID"
remove "42; rm -rf /"
[ ! -e "$t/looked-up" ] || fail "used a runner ID that isn't a number"
grep -q '::warning::Not a runner ID' "$t/log" || fail "warning: $(cat "$t/log")"
echo "ok - does nothing without a runner ID, or with one that isn't a number"

#!/bin/bash
# Checks profiles/profiles.json, the only copy of the profiles: each profile
# has job_minutes, runner_minutes and slurm, uses only the Slurm options
# test-ci-runner accepts, and keeps job < runner < Slurm minutes; and gh200.yml's
# timeout-minutes map matches it. Needs jq.
#
# Each profile:
#   job_minutes     the job's timeout-minutes in .github/workflows/gh200.yml
#   runner_minutes  how long the launcher lets the runner live
#   slurm           only --nodes=N, --gpus=N and --time=HH:MM:SS; --time is required
#   launcher        optional: where test-ci-runner's launch-runner.sh is on that
#                   cluster, an absolute path. Without it, the CI service's default
# job < runner < Slurm --time means GitHub stops the job first, then the launcher
# stops the runner, and Slurm never has to kill it.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
file=$root/profiles/profiles.json
die() { echo "profiles.json: $*" >&2; exit 1; }

jq -e 'type == "object" and length > 0 and all(.[];
         (keys - ["launcher"] | sort) == ["job_minutes", "runner_minutes", "slurm"]
         and (.job_minutes | type) == "number" and (.runner_minutes | type) == "number"
         and (.slurm | type) == "array" and all(.slurm[]; type == "string")
         and ((has("launcher") | not) or (.launcher | type == "string" and test("^/[A-Za-z0-9._/-]+$"))))' \
  "$file" >/dev/null \
  || die "each profile needs exactly job_minutes and runner_minutes (numbers) and slurm (a list of strings), and optionally launcher (an absolute path)"

while IFS=$'\t' read -r name job runner options; do
  [[ $name =~ ^[a-z0-9-]+$ ]] || die "bad profile name '$name'"
  slurm=""
  for o in $options; do
    if [[ $o =~ ^--(nodes|gpus)=[0-9]+$ ]]; then :
    elif [[ $o =~ ^--time=([0-9]+):([0-9]{2}):([0-9]{2})$ ]]; then
      slurm=$(( 10#${BASH_REMATCH[1]} * 60 + 10#${BASH_REMATCH[2]} + (10#${BASH_REMATCH[3]} > 0) ))
    else die "$name: Slurm option '$o' isn't one of --nodes=N, --gpus=N, --time=HH:MM:SS"
    fi
  done
  [ -n "$slurm" ] || die "$name: no --time"
  [ "$job" -lt "$runner" ] && [ "$runner" -lt "$slurm" ] \
    || die "$name: need job ($job) < runner ($runner) < Slurm ($slurm) minutes"
done < <(jq -r 'to_entries[] | [.key, .value.job_minutes, .value.runner_minutes, (.value.slurm | join(" "))] | @tsv' "$file")

want=$(jq -c 'with_entries(.value = .value.job_minutes)' "$file")
have=$(grep -o "fromJSON('{[^']*}')\[inputs.profile\]" "$root/.github/workflows/gh200.yml" \
  | sed "s/^fromJSON('//; s/')\[inputs.profile\]$//")
[ "$have" = "$want" ] || { echo "gh200.yml's timeout map is $have; profiles.json says $want" >&2; exit 1; }
echo "profiles OK: $want"

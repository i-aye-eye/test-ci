# test-ci


Run a script from your GitHub repo on Isambard-AI's GH200 nodes, using GitHub Actions with short-lived runners. This is one runner, in one Slurm job, for one job, which exits when the job ends.
Unlike CSCS's Gitlab instance, we do not need a mirror of your repo, and/or a long-running service on the cluster. We do need a PAT though.

This is a repo is what you call from your workflow. 
[test-ci-runner](https://github.com/i-aye-eye/test-ci-runner) is what runs on the Cluster

## What you write

```yaml
jobs:
  gh200:
    uses: i-aye-eye/test-ci/.github/workflows/gh200.yml@v0
    with:
      profile: gh200-1gpu      # 1 GPU, up to 50 minutes
      script: ci/gh200.sh      # run from your repo's root after checkout
      # args: "--quick"        # optional
      # image: ubuntu:24.04    # optional: run the script in this image with Apptainer
```

A full example is in [`examples/gh200-tests.yml`](examples/gh200-tests.yml), with a test script in [`examples/ci/gh200.sh`](examples/ci/gh200.sh). A matrix over `profile` gives one job per profile.

## Inputs

| Input | Default | Meaning |
|---|---|---|
| `profile` | required | The resources your job gets (below) |
| `script` | required | Path to the script in your repo, run from the repo's root after checkout |
| `args` | `""` | Arguments for the script |
| `image` | `""` | Run the script in this container image with Apptainer and the GPU, for example `ubuntu:24.04` |
| `dispatch` | `manual` | How the runner starts (below) |

## Profiles

We need some pre-set profiles for the user to choose, but larger node profiles will wait longer. `dev-cpu` is for local slurm container development only 

| Profile | Slurm | Job time limit |
|---|---|---|
| `gh200-1gpu` | 1 GPU, 1 hour | 50 min |
| `gh200-4gpu` | 4 GPUs on one node, 2 hours | 110 min |
| `dev-cpu` | No GPU, 30 minutes: ci-service's dev stack only | 20 min |

A profile can also say where test-ci-runner's launcher is on its cluster (`launcher` in `request-runner/profiles.json`), since each cluster has its own shared install. `dev-cpu` names the dev stack's; the `gh200-*` profiles get Isambard-AI's once its shared install exists. Without one, `request-runner` uses `/opt/test-ci-runner/launcher/launch-runner.sh`.


- It runs on a GH200 node as the Isambard-AI account the runner started under, with the usual `GITHUB_*` variables and node-local `TMPDIR` (in RAM).
- With `image`, each `run:` step runs in that image with the GPU, the workspace and `$HOME`; each step gets a fresh container. `uses:` steps such as checkout run on the node.
- No Docker: GitHub's `container:`, `services:` and Docker actions don't work. Call Apptainer or podman-hpc (not sure if this is working on I-AI yet?) from your script instead.
- It can submit Slurm jobs of its own as the same account. `sbatch --wait` returns the child job's exit code, so your step passes or fails with it. Cancel your child jobs if your script is interrupted: they outlive the CI job otherwise.

## What starts the runner

`gh200.yml` has three jobs. `request` runs on GitHub's own runner and, for `mvp`, asks the CI service for a runner; `run` waits in GitHub until that runner starts on Isambard-AI; `cleanup`, on GitHub's runner again, removes the runner if no job used it.

| `dispatch` | What starts the Slurm job | Human step | Runs as | Secrets |
|---|---|---|---|---|
| `manual` (Phase 1) | test-ci-runner's dispatcher, on an operator's laptop | None | Whoever dispatches | None |
| `mvp` (Phase A, dev) | ci-service's submitter, after a release | Release on the submitter page | The releaser's `user.project` | `origin-token`, `runner-admin-pat` |
| `service` (Phase B) | Not built yet | Release | The releaser's `user.project` | `origin-token` |
| `automatic` | Not built yet | None | The account registered for the repo | None |

**For `mvp`** (local dev only), the calling repo needs:

- the `BRICS_CI_URL` variable: ci-service's job API (the names are ci-service's);
- `secrets: origin-token: ${{ secrets.BRICS_CI_ORIGIN_TOKEN }}`;
- `secrets: runner-admin-pat: ${{ secrets.RUNNER_ADMIN_PAT }}`: a fine-grained PAT for that repo only, with Administration: write and a short expiry;
- `permissions: id-token: write` in the calling workflow, beside `contents: read`. Optional, but without it the CI service can't check where the job came from.

The request job first asks the job API whether it would accept the job (`POST /jobs/check`), and stops there if not, so a refused request leaves no runner registered on GitHub. Then it makes the runner config with the PAT and posts a short Slurm script to the job API. It holds the profile's `#SBATCH` lines, the runner config, and `exec <the profile's launcher> …` (on the dev stack, `/opt/test-ci-runner/launcher/launch-runner.sh`).
With `id-token: write`, it also sends GitHub's OIDC token for the job (audience `isambard-ci`), so the job API records the repo, commit and run, as GitHub signed them, and the release page shows them. That needs ci-service's `feature/github_oidc` or later; without the permission, the origin token alone is sent, as before.
Only the request job, which runs no code of yours, gets the token: the GH200 job is given `contents: read` alone, so your script can't get tokens for the CI service.

To release it, log in to the submitter, then paste the job's address from the run's summary into your browser and give your origin token. (With a ci-service from before its job IDs, the task token is in the request step's log instead.)
The runner config sits in that script, so it's stored in ci-service's database: dev only.

A runner config registers a runner on GitHub as soon as it's made. If the job is then refused after all, the request job removes it. If the job is never released, the run is cancelled, or the job times out waiting, the `cleanup` job removes it, with the same PAT; a Slurm job that starts after that stops at once. A runner that takes its job removes itself.

## Layout

```
.github/workflows/gh200.yml   the reusable workflow you call
request-runner/               the request job's action (mvp now; service in Phase B)
request-runner/profiles.json  the profiles: Slurm options and time limits. The only
                              copy; test-ci-runner reads it from here
remove-runner/                the cleanup job's action: removes a runner no job used
examples/                     a caller workflow and a test script
tests/                        shellcheck, actionlint, the profile check, request-runner,
                              remove-runner
```

## Versioning

Breaking changes mean a new major version has to be minted. A profile is changed in `request-runner/profiles.json` only: test-ci-runner's dispatcher reads that file at the version of `gh200.yml` each run uses.

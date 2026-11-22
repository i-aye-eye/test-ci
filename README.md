# test-ci

Run a script from your GitHub repo on Isambard-AI's GH200 nodes, using GitHub Actions with short-lived runners.

- Each CI job gets one runner, in one Slurm job, which exits when the CI job ends.
- There's no mirror of your repo, and no runner left running on the cluster.
- For now, your repo needs a PAT, until the GitHub App replaces it.

This repo is what you call from your workflow. [test-ci-runner](https://github.com/i-aye-eye/test-ci-runner) is what runs on the cluster.

## What you write

```yaml
permissions:
  contents: read
  id-token: write                # lets the CI service check which repo, commit and run this is

jobs:
  gh200:
    uses: i-aye-eye/test-ci/.github/workflows/gh200.yml@v0
    with:
      profile: gh200-1gpu        # 1 GPU, up to 50 minutes
      script: ci/gh200.sh        # run from your repo's root after checkout
      dispatch: mvp              # released on ci-service's submitter (below)
      # args: "--quick"          # optional
      # image: ubuntu:24.04      # optional: run the script in this image with Apptainer
    secrets:
      origin-token: ${{ secrets.BRICS_CI_ORIGIN_TOKEN }}
      runner-admin-pat: ${{ secrets.RUNNER_ADMIN_PAT }}
```

Set `dispatch` every time. It defaults to `manual`, which starts nothing unless an operator runs test-ci-runner's dispatcher, so the job would wait in GitHub for 24 hours and then be cancelled.

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

Pick the smallest profile that fits. Bigger ones can wait longer in the Slurm queue, because a whole node has to empty first.

| Profile | Slurm | Job time limit |
|---|---|---|
| `gh200-1gpu` | 1 GPU, 1 hour | 50 min |
| `gh200-4gpu` | 4 GPUs on one node, 2 hours | 110 min |
| `dev-cpu` | No GPU, 30 minutes: ci-service's dev stack only | 20 min |

A profile can also say where test-ci-runner's launcher is on its cluster (`launcher` in `request-runner/profiles.json`), since each cluster has its own shared install. Without one, `request-runner` uses `/opt/test-ci-runner/launcher/launch-runner.sh`.

- `dev-cpu` names the dev stack's install.
- The `gh200-*` profiles get Isambard-AI's once its shared install exists.

## What your script gets

- It runs on a GH200 node as the Isambard-AI account the runner started under, with the usual `GITHUB_*` variables and node-local `TMPDIR` (in RAM).
- With `image`, each `run:` step runs in that image with the GPU, the workspace and `$HOME`; each step gets a fresh container. `uses:` steps such as checkout run on the node.
- No Docker: GitHub's `container:`, `services:` and Docker actions don't work. Call Apptainer (`--nv`) or podman-hpc (`--gpu`) from your script instead; both run containers with the GPU.
- It can submit Slurm jobs of its own as the same account. `sbatch --wait` returns the child job's exit code, so your step passes or fails with it. Cancel your child jobs if your script is interrupted: they outlive the CI job otherwise.

## What starts the runner

`gh200.yml` has three jobs:

- `request` runs on GitHub's own runner and, for `mvp`, asks the CI service for a runner;
- `run` waits in GitHub until that runner starts on Isambard-AI;
- `cleanup`, on GitHub's runner again, removes the runner if no job used it.

| `dispatch` | What starts the Slurm job | Human step | Runs as | Secrets |
|---|---|---|---|---|
| `manual` | test-ci-runner's dispatcher, on an operator's laptop | None | Whoever dispatches | None |
| `mvp` | ci-service's submitter, after a release | Release on the submitter page | The releaser's `user.project` | `origin-token`, `runner-admin-pat` |
| `service` (with the GitHub App) | Not built yet | Release | The releaser's `user.project` | `origin-token` |
| `automatic` | Not built yet | None | The account registered for the repo | None |

### `mvp`

The calling repo needs:

- the `BRICS_CI_URL` variable: ci-service's job API (the names are ci-service's);
- `secrets: origin-token: ${{ secrets.BRICS_CI_ORIGIN_TOKEN }}`;
- `secrets: runner-admin-pat: ${{ secrets.RUNNER_ADMIN_PAT }}`: a fine-grained PAT for that repo only, with Administration: write and a short expiry;
- `permissions: id-token: write` in the calling workflow, beside `contents: read`. Optional, but without it the CI service can't check where the job came from.

The request job, which runs none of your code:

1. Gets GitHub's OIDC token for the job (audience `isambard-ci`), if the caller grants `id-token: write`.
2. Asks the job API whether it would accept the job (`POST /jobs/check`), and stops if not, so a refused request leaves no runner registered on GitHub.
3. Makes the runner config with the PAT.
4. Posts a short Slurm script to the job API (`POST /jobs`): the profile's `#SBATCH` lines, the runner config, and `exec <the profile's launcher> …`. The job API records the repo, commit and run from GitHub's token, and the release page shows them.

Only the request job gets the token. The GH200 job gets `contents: read` alone, so your script can't get tokens for the CI service.

To release it, log in to the submitter, open the job's address from the run's summary, and give your origin token. The runner config is in the script, so ci-service stores it; the job page hides it.

A runner config registers a runner on GitHub as soon as it's made. If the job is then refused after all, the request job removes it. If the job is never released, the run is cancelled, or the job times out waiting, the `cleanup` job removes it, with the same PAT; a Slurm job that starts after that stops at once. A runner that takes its job removes itself.

## Layout

```text
.
├── .github/workflows/
│   ├── gh200.yml          the reusable workflow you call
│   └── lint.yml           this repo's own checks
├── examples/              a caller workflow (gh200-tests.yml) and a test script (ci/gh200.sh)
├── request-runner/        the request job's action
│   └── profiles.json      the profiles: Slurm options and time limits. The only copy;
│                          test-ci-runner reads it from here
├── remove-runner/         the cleanup job's action: removes a runner no job used
└── tests/                 shellcheck, actionlint, the profile check, request-runner, remove-runner
```

## Versioning

Breaking changes mean a new major version. A profile is changed in `request-runner/profiles.json` only: test-ci-runner's dispatcher reads that file at the version of `gh200.yml` each run uses.

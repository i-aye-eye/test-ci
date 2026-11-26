# test-ci

Run a script from your GitHub repo on Isambard-AI's GH200 nodes, using GitHub Actions with short-lived runners.

- Each CI job gets one runner, in one Slurm job, which exits when the CI job ends.
- There's no mirror of your repo, and no runner left running on the cluster.
- `v1` uses the CI service's GitHub App (`dispatch: service`): your repo needs no secrets. `v0` has the older `dispatch: mvp`, with a PAT and an origin token, which the GitHub App replaces.

This repo is what you call from your workflow. [test-ci-runner](https://github.com/i-aye-eye/test-ci-runner) is what runs on the cluster.

## What you write

```yaml
permissions:
  contents: read

jobs:
  gh200:
    uses: i-aye-eye/test-ci/.github/workflows/gh200.yml@v1
    with:
      profile: gh200-1gpu        # 1 GPU, up to 50 minutes
      script: ci/gh200.sh        # run from your repo's root after checkout
      dispatch: service          # released on the CI service's submitter (below)
      # args: "--quick"          # optional
      # image: ubuntu:24.04      # optional: run the script in this image with Apptainer
```

Your repo also needs the `BRICS_CI_SUBMITTER_URL` variable, the CI service's GitHub App installed by its organisation, and to be registered with the CI service (see [`service`](#service)).

`dispatch` is required. Leave it out and GitHub refuses the run straight away ("Input dispatch is required"). It used to default to `manual`, where nothing starts a runner unless an operator runs test-ci-runner's dispatcher, so the job waited in GitHub for 24 hours and was then cancelled.

**When it runs.** Only on `push`, `pull_request`, `workflow_dispatch` and `schedule`, the events the CI service accepts. Pull requests from forks are skipped. On any other event, such as `pull_request_target` or `issue_comment`, which people outside your repo can start, both jobs are skipped, so call it from a workflow triggered by the four above.

A full example is in [`examples/gh200-tests.yml`](examples/gh200-tests.yml), with a test script in [`examples/ci/gh200.sh`](examples/ci/gh200.sh). A matrix over `profile` gives one job per profile.

## Inputs

| Input | Default | Meaning |
|---|---|---|
| `profile` | required | The resources your job gets (below) |
| `script` | required | Path to the script in your repo, run from the repo's root after checkout |
| `args` | `""` | Arguments for the script |
| `image` | `""` | Run the script in this container image with Apptainer and the GPU, for example `ubuntu:24.04` |
| `dispatch` | required | How the runner starts (below) |

## Profiles

Pick the smallest profile that fits. Bigger ones can wait longer in the Slurm queue, because a whole node has to empty first.

| Profile | Slurm | Job time limit |
|---|---|---|
| `gh200-1gpu` | 1 GPU, 1 hour | 50 min |
| `gh200-4gpu` | 4 GPUs on one node, 2 hours | 110 min |
| `dev-cpu` | No GPU, 30 minutes: ci-service's dev stack only | 20 min |

A profile can also say where test-ci-runner's launcher is on its cluster (`launcher` in `profiles/profiles.json`), since each cluster has its own shared install. Without one, the CI service uses `/opt/test-ci-runner/launcher/launch-runner.sh`.

- `dev-cpu` names the dev stack's install.
- The `gh200-*` profiles get Isambard-AI's once its shared install exists.

## What your script gets

- It runs on a GH200 node as the Isambard-AI account the runner started under, with the usual `GITHUB_*` variables and node-local `TMPDIR` (in RAM).
- With `image`, each `run:` step runs in that image with the GPU, the workspace and `$HOME`; each step gets a fresh container. `uses:` steps such as checkout run on the node.
- No Docker: GitHub's `container:`, `services:` and Docker actions don't work. Call Apptainer (`--nv`) or podman-hpc (`--gpu`) from your script instead; both run containers with the GPU.
- It can submit Slurm jobs of its own as the same account. `sbatch --wait` returns the child job's exit code, so your step passes or fails with it. Cancel your child jobs if your script is interrupted: they outlive the CI job otherwise.

## What starts the runner

`gh200.yml` has two jobs:

- `request` runs on GitHub's own runner, for `service`, and only says where to release the run;
- `run` waits in GitHub until its runner starts on Isambard-AI.

| `dispatch` | What starts the Slurm job | Human step | Runs as | Secrets |
|---|---|---|---|---|
| `manual` | test-ci-runner's dispatcher, on an operator's laptop | None | Whoever dispatches | None |
| `service` (with the GitHub App) | ci-service, after a release of the whole run | Release on the submitter's runs page | The releaser's `user.project` | None |
| `automatic` | Not built yet | None | The account registered for the repo | None |

### `service`

The CI service's GitHub App replaces the PAT, the origin token and the request. The calling repo needs:

- to be owned by an organisation that has installed the CI service's GitHub App on it;
- to be registered with the CI service as an App repo, to a BriCS project;
- the `BRICS_CI_SUBMITTER_URL` variable: the CI service's submitter, for the link to the release page. Without it, the run's summary says where to find the run, without a link.

No secrets, and no `id-token: write`.

What happens:

1. The `request` job writes the link to the run's page on the submitter to the run's summary, and does nothing else. The `run` job waits in GitHub, labelled with its profile and the run.
2. The CI service polls the repo with the App. Within about 20 seconds it finds the waiting run and keeps it, if it's the repo's own (not a fork's), came from one of the four events above, and calls this workflow at a version the service trusts.
3. Someone in a project the repo is registered to logs in to the submitter, opens the link (or "Runs to release"), and releases the whole run as one of their project's accounts.
4. The CI service makes a runner for each waiting job, only then, in the organisation's runner group, which only this workflow's jobs can use. It submits a Slurm job with the profile's settings, and the runner takes the job.

There's no `cleanup` job: nothing makes a runner before the release. A runner made at the release that no job uses is the CI service's to remove.

## Layout

```text
.
├── .github/workflows/
│   ├── gh200.yml          the reusable workflow you call
│   └── lint.yml           this repo's own checks
├── examples/              a caller workflow (gh200-tests.yml) and a test script (ci/gh200.sh)
├── profiles/
│   └── profiles.json      the profiles: Slurm options and time limits. The only copy;
│                          the CI service and test-ci-runner read it from here
└── tests/                 shellcheck, actionlint, the profile check and the event check
```

## Versioning

Breaking changes mean a new major version.

- `v1`: `dispatch: service`, with the CI service's GitHub App. No secrets.
- `v0`: `dispatch: mvp`, with a PAT and an origin token, and `manual`. The tag keeps `mvp`'s actions; `main` no longer has them.

A profile is changed in `profiles/profiles.json` only: the CI service and test-ci-runner's dispatcher read it at the version of `gh200.yml` each run uses.

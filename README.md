# github-group-runner

Self-hosted GitHub Actions runners for the `mirrorstack-ai` org: ephemeral,
docker-in-docker, ARM64, authenticated through a GitHub App, scaled by a
one-minute cron job that never kills a running job.

Runs today on a DGX Spark. Nothing here is Spark-specific beyond the default
runner group, name prefix and labels, all of which come from `.env`.

## What is here

| File | Role |
|---|---|
| `Dockerfile` | `ubuntu:24.04` + the actions runner (version and SHA pinned as build args) + docker CLI. Runs as uid 1001 `runner`. |
| `entrypoint.sh` | Mints a registration token, registers an **ephemeral** runner named `<prefix>-<container id>` in the runner group, deregisters on exit. |
| `dind-entrypoint.sh` | Runs as root first: starts a dockerd private to the container (the service is `privileged`), copies the App key to a runner-readable path, then hands off to `entrypoint.sh`. |
| `docker-compose.yml` | One `runner` service. Replica count is owned by the autoscaler; `RUNNER_REPLICAS` only matters on a cold start. Each replica gets its own anonymous `/var/lib/docker` volume. |
| `scripts/autoscale.sh` | `desired = clamp(MIN, MAX, busy + HEADROOM)`. Scale-up uses `--scale`; scale-down stops specific idle containers. Logs to `autoscale.log`. |
| `lib/gh-token.sh` | Resolves credentials: GitHub App installation token (preferred, 1 h, re-minted per call) or a PAT via `GH_TOKEN`. |

## Setup

1. Create a GitHub App with the org permission **Self-hosted runners: read and
   write**, install it on the org, and save its private key as
   `secrets/app-key.pem` (mode 600, owned by root is fine: the container copies
   it as root).
2. `cp .env.example .env` and set `GH_OWNER`, `GH_APP_ID`, the runner group,
   prefix and labels.
3. Build and cold-start:

   ```bash
   docker compose build
   docker compose up -d
   ```

4. Install the autoscaler on the host (it runs outside the containers):

   ```
   * * * * * /bin/bash /path/to/github-group-runner/scripts/autoscale.sh >/dev/null 2>&1
   ```

The scaler sources `.env` itself and needs `GH_APP_KEY_PATH` to be a host path.

## Autoscaler rules, and why each exists

- **Idle means two things at the moment of action:** no `Runner.Worker`
  process in the container (read from the host with `docker top`), and a
  listener at least `RUNNER_IDLE_MIN_AGE` seconds old (default 90). A fresh
  listener is the one most likely to take the next queued job.
- **Leaving is polite.** The container's restart policy is set to `no`, the
  listener gets SIGTERM, and it has `RUNNER_STOP_GRACE` seconds (default 120)
  to deregister and exit. A container that picks up a job in that window is
  left alone and logged as deferred.
- **No thrash.** No scale-down within `RUNNER_SCALE_DOWN_COOLDOWN` seconds of
  the last scale-up (default 300), at most `RUNNER_SCALE_DOWN_MAX` removals per
  tick (default 2), and a `flock` so two ticks never overlap.
- **Never `--scale` down.** Compose removes the highest-numbered containers
  regardless of whether they are mid-job.

History behind the rules (2026-09-14): idle used to be judged from one GitHub
API snapshot taken at the top of the tick. A runner that accepted a job in the
seconds between that snapshot and its `docker stop` was killed mid-job, and
GitHub reported the job dead at about 601 s with "lost communication with the
server". Over two days, 26 of 28 such deaths matched a "removed idle" log line
2 to 36 s after the job started. After the change above: zero.

## Operating

- Health: `docker compose ps` and `tail -f autoscale.log`. A healthy log shows
  `steady:` lines once a minute and removals that are "gone after" single-digit
  seconds.
- `RUNNER_NAME_PREFIX` is a prefix. Do not pin full runner names; a pinned name
  is why a dead runner once never came back.
- Runners that die uncleanly leave an "offline" registration in the org's
  runner list. They are harmless; prune by hand when they annoy you.
- GPU jobs: uncomment the `/dev/nvidia0` mount in the compose file. The GPU is
  then shared by every replica.
- macOS/OrbStack: bind-mounting the key hangs the container; set
  `GH_APP_PRIVATE_KEY_B64` instead of `GH_APP_KEY_PATH`.

## Not in git

`.env`, `secrets/`, `autoscale.log`, `.autoscale.lock`, `.autoscale.state` and
`*.bak-*` are ignored. Never commit a key or a live env file to this public
repo.

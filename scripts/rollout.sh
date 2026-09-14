#!/usr/bin/env bash
# Rolling recreate of the runner fleet onto the current image WITHOUT killing a
# job: drain old-image containers one at a time (same rules as the autoscaler),
# top the pool back up from the new image after each one, finish with
# scripts/verify-scrub.sh. Holds .autoscale.lock the whole time, so cron ticks
# log "skip: previous tick still running" instead of fighting it.
#
#   scripts/rollout.sh            # docker compose build, then roll
#   scripts/rollout.sh --no-build # roll onto whatever the image tag holds now
#
# `restart: always` re-runs the OLD image, so a rebuild without this changes
# nothing. Env: ROLLOUT_TIMEOUT (s, default 1800), RUNNER_STOP_GRACE (s, 120).
set -uo pipefail
PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$PROJECT" || exit 1
say() { printf '[%s] rollout: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "${PROJECT}/autoscale.log"; }

exec 9>"${PROJECT}/.autoscale.lock"
flock -w 180 9 || { say "could not take .autoscale.lock in 180 s — is an autoscaler tick stuck?"; exit 1; }

set -a; . ./.env; set +a
. ./lib/gh-token.sh
. ./lib/runners.sh
[[ -n "${GH_APP_KEY_PATH:-}" ]] && GH_APP_PRIVATE_KEY="${GH_APP_KEY_PATH}"
GH_APP_KEY_TMP="$(mktemp)"; chmod 600 "$GH_APP_KEY_TMP"
trap 'rm -f "$GH_APP_KEY_TMP"' EXIT
resolve_gh_token "${GH_OWNER}" >/dev/null 2>&1 || { say "auth failed"; exit 1; }

IMAGE="$(docker compose config --format json 2>/dev/null | jq -r '.services.runner.image // "gh-runner-dgx:local"')"
STOP_GRACE="${RUNNER_STOP_GRACE:-120}"
TIMEOUT="${ROLLOUT_TIMEOUT:-1800}"
PREFIX="${RUNNER_NAME_PREFIX:-dgx-spark}"

if [[ "${1:-}" != "--no-build" ]]; then
  say "building ${IMAGE}"
  env -u GH_APP_PRIVATE_KEY docker compose build --quiet runner || { say "build FAILED"; exit 1; }
fi
target="$(docker image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null)"
[[ -z "$target" ]] && { say "image ${IMAGE} not found"; exit 1; }
count="$(docker compose ps -q runner 2>/dev/null | wc -l | tr -d ' ')"
say "target image ${target#sha256:}, pool ${count}"

old_containers() {
  local cid
  for cid in $(docker compose ps -q runner 2>/dev/null); do
    [[ "$(docker inspect --format '{{.Image}}' "$cid" 2>/dev/null)" == "$target" ]] || echo "$cid"
  done
}
top_up() {
  # --no-recreate: new containers come from the new image, existing ones are
  # left exactly as they are. -u GH_APP_PRIVATE_KEY: see autoscale.sh.
  env -u GH_APP_PRIVATE_KEY docker compose up -d --no-recreate --scale "runner=${count}" >/dev/null 2>&1 \
    || say "top-up FAILED (compose up)"
}

# After the FIRST replacement: wait for a new-image container to reach its
# listener and prove the scrub on it before touching the rest of the fleet. A
# broken image then costs one container, not the pool.
canary() {
  # verify-scrub judges a container only once PID 1 carries RUNNER_REGISTERED=1
  # (post-scrub re-exec); before that it answers 2 = not judged yet, so wait.
  local cid out rc until=$(( $(date +%s) + 300 ))
  while (( $(date +%s) < until )); do
    for cid in $(docker compose ps -q runner 2>/dev/null); do
      [[ "$(docker inspect --format '{{.Image}}' "$cid" 2>/dev/null)" == "$target" ]] || continue
      out="$("${PROJECT}/scripts/verify-scrub.sh" "$cid" 2>&1)"; rc=$?
      case $rc in
        0) printf '%s\n' "$out" | tee -a "${PROJECT}/autoscale.log"; say "canary OK on ${cid:0:12}"; return 0;;
        1) printf '%s\n' "$out" | tee -a "${PROJECT}/autoscale.log"
           say "canary FAILED on ${cid:0:12} — aborting; the rest of the fleet stays on the old image"; return 1;;
      esac
    done
    sleep 5
  done
  say "canary: no new-image container finished registering in 300 s — aborting (docker logs the new container)"
  return 1
}

deadline=$(( $(date +%s) + TIMEOUT ))
pass=0
canary_done=0
while :; do
  mapfile -t old < <(old_containers)
  (( ${#old[@]} == 0 )) && break
  if (( $(date +%s) > deadline )); then
    say "TIMEOUT: ${#old[@]} old container(s) still running jobs — re-run later"; exit 1
  fi
  pass=$(( pass + 1 ))
  say "pass ${pass}: ${#old[@]} container(s) on the old image"
  for cid in "${old[@]}"; do
    name="${PREFIX}-$(docker inspect --format '{{.Config.Hostname}}' "$cid" 2>/dev/null)"
    if has_worker "$cid"; then say "  ${name}: job running, later"; continue; fi
    if waited=$(drain_container "$cid" "$STOP_GRACE"); then
      say "  replaced ${name}: old container gone after ${waited}s"
      say "  $(deregister_runner "$name")"
    else
      say "  ${name}: a job landed during the drain — left alone"
      continue
    fi
    top_up
    if (( canary_done == 0 )); then canary || exit 1; canary_done=1; fi
  done
  (( $(old_containers | wc -l) > 0 )) && sleep 30
done
top_up
say "every container is on ${target#sha256:}; waiting for listeners"
for ((i = 0; i < 90; i++)); do
  pending=0
  for cid in $(docker compose ps -q runner 2>/dev/null); do has_listener "$cid" || pending=$(( pending + 1 )); done
  (( pending == 0 )) && break
  sleep 2
done
say "verify-scrub:"
"${PROJECT}/scripts/verify-scrub.sh" | tee -a "${PROJECT}/autoscale.log"

#!/usr/bin/env bash
# Scales the runner pool between RUNNER_MIN and RUNNER_MAX.
#
# desired = clamp(MIN, MAX, busy + HEADROOM)
#   busy    = our runners currently executing a job (online only)
#   HEADROOM= spare idle runners kept ready to grab the next queued job
#
# Scale UP is just `compose up -d --scale`. Scale DOWN never uses --scale:
# compose would remove the highest-numbered containers regardless of whether
# they are mid-job. Instead we pick specific IDLE containers and stop them, so a
# running job is never killed.
#
# 2026-09-14: "idle" used to be judged from ONE GitHub API snapshot taken at the
# top of the run; a runner that accepted a job in the seconds between that
# snapshot and its `docker stop` was killed mid-job, and GitHub reported the
# job dead at ~601 s ("lost communication with the server"). Measured
# 09-12..09-14: 26 of 28 such deaths matched a "removed idle" line 2-36 s after
# the job started. Now:
#   - a container is idle only if NO Runner.Worker process exists in it at the
#     moment we act (read from the host with docker top) AND its listener has
#     been up for at least IDLE_MIN_AGE seconds (a fresh listener is the one
#     most likely to grab the next queued job);
#   - the runner is asked to leave by SIGTERM to the LISTENER and given
#     STOP_GRACE seconds to exit and deregister; it is never SIGKILLed while a
#     job is running;
#   - scale-down waits SCALE_DOWN_COOLDOWN seconds after the last scale-up and
#     removes at most SCALE_DOWN_MAX containers per tick, so the pool stops
#     thrashing up and down every minute (186 ups / 176 downs in 46 h).
set -uo pipefail

PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$PROJECT" || exit 1
LOG="${PROJECT}/autoscale.log"
say() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

set -a; . ./.env; set +a
. ./lib/gh-token.sh

# This script runs on the HOST, not in a container. .env carries the host path
# as GH_APP_KEY_PATH, while GH_APP_PRIVATE_KEY (/run/secrets/app-key.pem) is a
# container-only path that does not exist out here. Without this line
# resolve_gh_token finds no credentials and the scaler silently never runs.
#
# Deliberately NOT exported: this var is also the name docker-compose.yml
# substitutes into the container's GH_APP_PRIVATE_KEY (default
# /run/secrets/app-key.pem). Exporting it here leaked the host path into the
# `docker compose up` call below, overriding that default and pointing every
# container at a .pem path that doesn't exist inside it — a plain reassignment
# still satisfies resolve_gh_token, which runs in this same shell.
[[ -n "${GH_APP_KEY_PATH:-}" ]] && GH_APP_PRIVATE_KEY="${GH_APP_KEY_PATH}"

MIN="${RUNNER_MIN:-4}"
MAX="${RUNNER_MAX:-16}"
HEADROOM="${RUNNER_HEADROOM:-2}"
PREFIX="${RUNNER_NAME_PREFIX:-dgx-spark}"
IDLE_MIN_AGE="${RUNNER_IDLE_MIN_AGE:-90}"                 # s a listener must be up before it counts as idle
STOP_GRACE="${RUNNER_STOP_GRACE:-120}"                    # s we wait for a runner to exit + deregister
SCALE_DOWN_COOLDOWN="${RUNNER_SCALE_DOWN_COOLDOWN:-300}"  # s after a scale-up during which we never scale down
SCALE_DOWN_MAX="${RUNNER_SCALE_DOWN_MAX:-2}"              # containers removed per tick, at most
STATE="${PROJECT}/.autoscale.state"                       # epoch of the last successful scale-up

# One tick at a time: a scale-down can wait up to STOP_GRACE per container,
# and cron fires every minute regardless (13:06: a v1 tick was still draining
# when the next tick started — two scalers acting on one snapshot each).
exec 9>"${PROJECT}/.autoscale.lock"
flock -n 9 || { say "skip: previous tick still running"; exit 0; }

docker info >/dev/null 2>&1 || { say "docker unreachable"; exit 0; }

GH_APP_KEY_TMP="$(mktemp)"; chmod 600 "$GH_APP_KEY_TMP"
trap 'rm -f "$GH_APP_KEY_TMP"' EXIT
resolve_gh_token "${GH_OWNER}" >/dev/null 2>&1 || { say "auth failed"; exit 1; }

RUNNERS="$(curl -sS -H "Authorization: Bearer ${GH_API_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/orgs/${GH_OWNER}/actions/runners?per_page=100" 2>/dev/null)"
[[ -z "$RUNNERS" ]] && { say "runner list failed"; exit 1; }

# Only OUR runners, and only online — a stale "offline busy=true" entry would
# otherwise inflate demand forever and pin the pool at MAX.
busy=$(jq -r --arg p "$PREFIX" \
  '[.runners[] | select(.name|startswith($p)) | select(.busy and .status=="online")] | length' <<<"$RUNNERS")
busy_names=$(jq -r --arg p "$PREFIX" \
  '.runners[] | select(.name|startswith($p)) | select(.busy and .status=="online") | .name' <<<"$RUNNERS")

# wc -l, NOT `grep -c . || echo 0`: with no containers grep prints "0" AND
# exits 1, so the || fires too and current becomes "0\n0" — every arithmetic
# test then dies with "bad math expression".
current=$(docker compose ps -q runner 2>/dev/null | wc -l | tr -d " ")

desired=$(( busy + HEADROOM ))
(( desired < MIN )) && desired=$MIN
(( desired > MAX )) && desired=$MAX

if (( desired == current )); then
  say "steady: busy=${busy} current=${current} (min=${MIN} max=${MAX})"
  exit 0
fi

if (( desired > current )); then
  say "scale UP ${current} -> ${desired} (busy=${busy})"
  # -u GH_APP_PRIVATE_KEY: guard against it being exported by whatever invoked
  # this script (cron env, a shell profile, ...) — the container must get
  # compose's own default (/run/secrets/app-key.pem), never the host path.
  env -u GH_APP_PRIVATE_KEY docker compose up -d --scale "runner=${desired}" >/dev/null 2>&1 \
    && { say "scaled up ok"; date +%s > "$STATE"; } || say "scale up FAILED"
  exit 0
fi

# ---- scale down: cooldown after a scale-up, capped per tick ----------------
last_up=$(cat "$STATE" 2>/dev/null || echo 0)
since_up=$(( $(date +%s) - last_up ))
if (( since_up < SCALE_DOWN_COOLDOWN )); then
  say "hold: want ${current} -> ${desired} (busy=${busy}) but the last scale-up was ${since_up}s ago (< ${SCALE_DOWN_COOLDOWN}s)"
  exit 0
fi

remove=$(( current - desired ))
(( remove > SCALE_DOWN_MAX )) && remove=$SCALE_DOWN_MAX
say "scale DOWN ${current} -> ${desired} (busy=${busy}), removing up to ${remove} idle"

# A job is running in a container iff a Runner.Worker process exists in it.
# Read from the HOST at the instant we act — the API snapshot above lags job
# assignment by up to ~30 s, which is exactly the window that killed jobs.
has_worker()   { docker top "$1" -o pid,args 2>/dev/null | grep -q '[R]unner\.Worker'; }
is_running()   { docker inspect --format '{{.State.Running}}' "$1" 2>/dev/null | grep -q true; }
# Seconds the listener has been up. docker top insists on a pid column, so
# etimes rides next to it; if the listener is not up yet (dind stagger,
# registration) fall back to the container's own age, which is always >= it.
listener_age() {
  local a
  a="$(docker top "$1" -o pid,etimes,args 2>/dev/null | awk '/[R]unner\.Listener/ {print $2; exit}')"
  if [[ -z "$a" ]]; then
    local s; s="$(docker inspect --format '{{.State.StartedAt}}' "$1" 2>/dev/null)"
    [[ -n "$s" ]] && a=$(( $(date +%s) - $(date -d "$s" +%s 2>/dev/null || echo 0) ))
  fi
  echo "${a:-}"
}

removed=0
for cid in $(docker compose ps -q runner 2>/dev/null); do
  (( removed >= remove )) && break
  short="$(docker inspect --format '{{.Config.Hostname}}' "$cid" 2>/dev/null)"
  name="${PREFIX}-${short}"
  if grep -qx "$name" <<<"$busy_names"; then
    continue                      # mid-job per GitHub — leave it alone
  fi
  if has_worker "$cid"; then
    say "  skip ${name}: job running (Runner.Worker present, API said idle)"
    continue
  fi
  age="$(listener_age "$cid")"
  if [[ -z "$age" ]] || (( age < IDLE_MIN_AGE )); then
    say "  skip ${name}: listener ${age:-absent}s old (< ${IDLE_MIN_AGE}s)"
    continue
  fi
  # The service is `restart: always`: when the listener exits the container
  # comes straight back with a FRESH registration that grabs the next queued
  # job (measured 12:50-12:57: every removal ran the full grace and four
  # "idle" containers were busy again by the end of it). Pin it down first.
  docker update --restart=no "$cid" >/dev/null 2>&1
  # Ask the LISTENER itself to leave. Idle, it exits at once and entrypoint.sh
  # deregisters. If a job landed in the last few ms the runner cancels and
  # REPORTS it instead of the job hanging as an orphan for 10 minutes.
  docker exec "$cid" pkill -TERM -x Runner.Listener >/dev/null 2>&1
  waited=0
  while (( waited < STOP_GRACE )) && is_running "$cid"; do
    sleep 1; waited=$(( waited + 1 ))
  done
  if is_running "$cid"; then
    if has_worker "$cid"; then
      say "  ${name}: running a job after ${waited}s — NOT killing it, deferred"
      continue
    fi
    docker stop -t 30 "$cid" >/dev/null 2>&1
  fi
  docker rm "$cid" >/dev/null 2>&1 || docker rm -f "$cid" >/dev/null 2>&1
  removed=$(( removed + 1 ))
  say "  removed idle ${name} (listener ${age}s old, gone after ${waited}s)"
done

(( removed < remove )) && say "only ${removed}/${remove} were idle; rest deferred"
say "scale down done (removed=${removed})"

#!/usr/bin/env bash
# Host-side helpers shared by scripts/autoscale.sh and scripts/rollout.sh.
# Sourced. Needs docker, jq, curl; deregister_runner needs GH_API_TOKEN and
# GH_OWNER (resolve_gh_token from lib/gh-token.sh sets the former).

# A job is running in a container iff a Runner.Worker process exists in it.
# Read from the HOST at the instant we act — the API snapshot lags job
# assignment by up to ~30 s, which is exactly the window that killed jobs.
has_worker()   { docker top "$1" -o pid,args 2>/dev/null | grep -q '[R]unner\.Worker'; }
# "run", not just any Runner.Listener: config.sh spawns `Runner.Listener configure`
# during registration, and that one must not count as the runner being up.
has_listener() { docker top "$1" -o pid,args 2>/dev/null | grep -q '[R]unner\.Listener run'; }
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

# Ask an idle container to leave without ever killing a job.
#
# 🔴 DEREGISTER FIRST, THEN STOP. GitHub refuses to delete a runner that has a
# job assigned (HTTP 422), and that refusal is the only race-free "is it busy"
# test there is: a process check from the host misses the seconds between
# assignment and the Worker starting. 19:17:43 on 09-14 a roll saw no Worker,
# SIGTERMed the listener, the container was gone in 1 s — and the DELETE one
# second later answered 422, because a deploy job had been assigned 9 s
# earlier. The job hung for 10 minutes as "lost communication". A runner
# whose registration is deleted can no longer be assigned anything, so from
# 204 on, stopping the container is safe.
#
# Pin the restart policy first (restart: always would bring it straight back
# with a fresh registration). Prints the seconds waited.
# Returns 0 = removed, 1 = deferred (busy per GitHub or a Worker appeared).
drain_container() {
  local cid="$1" grace="$2" waited=0 name code
  name="$(runner_name_of "$cid")"
  docker update --restart=no "$cid" >/dev/null 2>&1
  code="$(deregister_runner_code "$name")"
  case "$code" in
    204|404) ;;                      # gone from GitHub: nothing can be assigned to it now
    *) docker update --restart=always "$cid" >/dev/null 2>&1; echo 0; return 1;;   # 422 = busy; leave it exactly as it was
  esac
  docker exec "$cid" pkill -TERM -x Runner.Listener >/dev/null 2>&1
  while (( waited < grace )) && is_running "$cid"; do sleep 1; waited=$(( waited + 1 )); done
  if is_running "$cid"; then
    # A Worker here means a job was already running before the delete (the
    # delete would have been refused) — impossible by construction, but never
    # kill it if it happens; let it finish and report.
    if has_worker "$cid"; then echo "$waited"; return 1; fi
    docker stop -t 30 "$cid" >/dev/null 2>&1
  fi
  docker rm "$cid" >/dev/null 2>&1 || docker rm -f "$cid" >/dev/null 2>&1
  echo "$waited"
  return 0
}

runner_name_of() { echo "${RUNNER_NAME_PREFIX:-dgx-spark}-$(docker inspect --format '{{.Config.Hostname}}' "$1" 2>/dev/null)"; }

# DELETE the registration by name. Prints the HTTP code: 204 deleted, 404 not
# registered (GitHub already removed an ephemeral runner that finished a job),
# 422 busy, anything else = API trouble (treated as busy by the caller).
deregister_runner_code() {
  local n="$1" list id
  list="$(curl -sS -H "Authorization: Bearer ${GH_API_TOKEN}" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/orgs/${GH_OWNER}/actions/runners?per_page=100" 2>/dev/null)"
  id="$(jq -r --arg n "$n" '.runners[]? | select(.name==$n) | .id' <<<"$list" 2>/dev/null | head -1)"
  [[ -z "$id" ]] && { echo 404; return 0; }
  curl -sS -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: Bearer ${GH_API_TOKEN}" \
    -H "Accept: application/vnd.github+json" "https://api.github.com/orgs/${GH_OWNER}/actions/runners/${id}" 2>/dev/null || echo 000
}

# Delete ONE runner's registration by name — the runner we just removed. The
# container cannot do it any more (it scrubs its credentials after registering,
# core-v2#1503). Never a sweep: stale offline entries are the owner's to prune.
# Prints a one-line result; never fails the caller.
deregister_runner() {
  local n="$1" list id code
  list="$(curl -sS -H "Authorization: Bearer ${GH_API_TOKEN}" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/orgs/${GH_OWNER}/actions/runners?per_page=100" 2>/dev/null)"
  id="$(jq -r --arg n "$n" '.runners[]? | select(.name==$n) | .id' <<<"$list" 2>/dev/null | head -1)"
  [[ -z "$id" ]] && { echo "no registration for ${n} (GitHub already removed it)"; return 0; }
  code="$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: Bearer ${GH_API_TOKEN}" \
    -H "Accept: application/vnd.github+json" "https://api.github.com/orgs/${GH_OWNER}/actions/runners/${id}" 2>/dev/null)"
  case "$code" in
    204|404) echo "deregistered ${n} (id ${id})";;
    *)       echo "deregister ${n} FAILED (id ${id}, HTTP ${code}) — shows offline until pruned";;
  esac
  return 0
}

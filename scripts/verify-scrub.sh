#!/usr/bin/env bash
# Asserts from the host that no running runner container exposes a GitHub
# credential to the uid job steps run as (1001) — the property of core-v2#1503.
#
# A container is only judged once it is past registration: entrypoint.sh
# re-execs itself with RUNNER_REGISTERED=1 right after the scrub, so that marker
# on PID 1 means "a job can start from here on". Before it, the key and the
# token legitimately exist (config.sh needs them, and it runs its own
# `Runner.Listener configure` process — 15:10 on 09-14 a check keyed on "a
# Runner.Listener exists" fired during registration and aborted a rollout).
#
# Checks, as uid 1001, in every container past registration:
#   - the staged key /home/runner/.gh-app-key.pem does not exist
#   - the mounted key /run/secrets/app-key.pem is not readable AND non-empty
#   - neither PID 1 nor a `Runner.Listener run` process carries GH_API_TOKEN /
#     GH_TOKEN / GH_APP_PRIVATE_KEY(_B64) / GH_APP_ID in /proc/<pid>/environ
#
# Usage: scripts/verify-scrub.sh [container-id ...]   (default: every runner container)
# Exit 0 = every judged container clean, 1 = a hit (printed), 2 = nothing judged yet.
set -uo pipefail
PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$PROJECT" || exit 2
ids="${*:-$(docker compose ps -q runner 2>/dev/null)}"
[[ -z "$ids" ]] && { echo "verify-scrub: no runner containers"; exit 2; }
rc=0; n=0; skipped=0
for cid in $ids; do
  name="$(docker inspect --format '{{.Config.Hostname}}' "$cid" 2>/dev/null)"
  out="$(docker exec -u 1001 "$cid" sh -c '
    if ! tr "\0" "\n" < /proc/1/environ 2>/dev/null | grep -qx "RUNNER_REGISTERED=1"; then
      echo "registering"; exit 3
    fi
    hit=0
    [ -e /home/runner/.gh-app-key.pem ] && { echo "    staged key exists: /home/runner/.gh-app-key.pem"; hit=1; }
    if [ -r /run/secrets/app-key.pem ] && [ -s /run/secrets/app-key.pem ]; then
      echo "    mounted key readable by uid 1001: /run/secrets/app-key.pem"; hit=1
    fi
    pids=1
    for p in $(pgrep -x Runner.Listener 2>/dev/null); do
      case "$(tr "\0" " " < /proc/$p/cmdline 2>/dev/null)" in *"Runner.Listener run"*) pids="$pids $p";; esac
    done
    for p in $pids; do
      v=$(tr "\0" "\n" < /proc/$p/environ 2>/dev/null \
          | grep -E "^(GH_API_TOKEN|GH_TOKEN|GH_APP_PRIVATE_KEY|GH_APP_PRIVATE_KEY_B64|GH_APP_ID)=" \
          | cut -d= -f1 | tr "\n" " ")
      [ -n "$v" ] && { echo "    pid $p environ carries: $v"; hit=1; }
    done
    exit $hit' 2>&1)"
  r=$?
  if [[ $r -eq 3 ]]; then
    echo "..  ${name}: still registering (no RUNNER_REGISTERED=1 on pid 1 yet), not judged"
    skipped=$(( skipped + 1 )); continue
  fi
  n=$(( n + 1 ))
  if [[ $r -eq 0 ]]; then echo "ok  ${name}"; else echo "HIT ${name}"; printf '%s\n' "$out"; rc=1; fi
done
if [[ $rc -ne 0 ]]; then
  echo "verify-scrub: CREDENTIALS EXPOSED in at least one container"; exit 1
fi
if [[ $n -eq 0 ]]; then
  echo "verify-scrub: nothing judged yet (${skipped} still registering)"; exit 2
fi
echo "verify-scrub: ${n} container(s) judged as uid 1001, credentials absent in all; ${skipped} still registering"
exit 0

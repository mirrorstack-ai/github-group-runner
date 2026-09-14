#!/usr/bin/env bash
# Asserts from the host that no running runner container exposes a GitHub
# credential to the uid job steps run as (1001) — the property of core-v2#1503.
# Checks, as uid 1001, in every container whose listener is up:
#   - the staged key /home/runner/.gh-app-key.pem does not exist
#   - the mounted key /run/secrets/app-key.pem is not readable AND non-empty
#   - neither PID 1 nor the Runner.Listener carries GH_API_TOKEN / GH_TOKEN /
#     GH_APP_PRIVATE_KEY(_B64) / GH_APP_ID in /proc/<pid>/environ
# Exit 0 = every checked container clean, 1 = a hit (printed), 2 = nothing to check.
set -uo pipefail
PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$PROJECT" || exit 2
ids="$(docker compose ps -q runner 2>/dev/null)"
[[ -z "$ids" ]] && { echo "verify-scrub: no runner containers"; exit 2; }
rc=0; n=0; skipped=0
for cid in $ids; do
  name="$(docker inspect --format '{{.Config.Hostname}}' "$cid" 2>/dev/null)"
  if ! docker top "$cid" -o pid,args 2>/dev/null | grep -q '[R]unner\.Listener'; then
    echo "..  ${name}: listener not up yet (still registering), skipped"
    skipped=$(( skipped + 1 )); continue
  fi
  n=$(( n + 1 ))
  out="$(docker exec -u 1001 "$cid" sh -c '
    hit=0
    [ -e /home/runner/.gh-app-key.pem ] && { echo "    staged key exists: /home/runner/.gh-app-key.pem"; hit=1; }
    if [ -r /run/secrets/app-key.pem ] && [ -s /run/secrets/app-key.pem ]; then
      echo "    mounted key readable by uid 1001: /run/secrets/app-key.pem"; hit=1
    fi
    for p in 1 $(pgrep -x Runner.Listener 2>/dev/null); do
      v=$(tr "\0" "\n" < /proc/$p/environ 2>/dev/null \
          | grep -E "^(GH_API_TOKEN|GH_TOKEN|GH_APP_PRIVATE_KEY|GH_APP_PRIVATE_KEY_B64|GH_APP_ID)=" \
          | cut -d= -f1 | tr "\n" " ")
      [ -n "$v" ] && { echo "    pid $p environ carries: $v"; hit=1; }
    done
    exit $hit' 2>&1)"
  r=$?
  if [[ $r -eq 0 ]]; then echo "ok  ${name}"; else echo "HIT ${name}"; printf '%s\n' "$out"; rc=1; fi
done
if [[ $rc -eq 0 ]]; then
  echo "verify-scrub: ${n} container(s) checked as uid 1001, credentials absent in all; ${skipped} skipped (no listener yet)"
else
  echo "verify-scrub: CREDENTIALS EXPOSED in at least one container"
fi
exit $rc

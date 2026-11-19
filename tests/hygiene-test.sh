#!/usr/bin/env bash
# Tests for the disk hygiene on the shared host: the volume ledger, the sweeper,
# `docker rm -v`, the inner-dockerd prune and the disk guard in autoscale.sh.
# Everything runs against a FAKE docker (plus fake df/curl/flock) first on PATH;
# the real daemon is never touched. Runs anywhere with bash 3.2+ and jq.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
FAKE="$T/fake"; mkdir -p "$T/bin" "$FAKE"
export FAKE PATH="$T/bin:$PATH" RUNNER_LEDGER="$T/state/our-volumes.txt"
fail=0
check() { local what="$1"; shift; "$@" >/dev/null 2>&1 || { echo "FAIL: ${what}"; fail=1; }; }
nocheck() { local what="$1"; shift; if "$@" >/dev/null 2>&1; then echo "FAIL: ${what}"; fail=1; fi; }
V() { printf '%064x\n' "$1"; }                                # a 64-hex anonymous volume name
calls() { grep -c "^$1" "$FAKE/calls.log"; }                  # how many fake-docker calls start with $1
lines() { wc -l < "$1" | tr -d ' '; }

# ---- fakes -------------------------------------------------------------------
cat > "$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
# Fake docker. State lives in $FAKE: all / dangling (volume names), containers
# (compose ps), mount.<cid> (the volume at /var/lib/docker). Every call is logged.
echo "$*" >> "$FAKE/calls.log"
case "$1 ${2:-}" in
  "volume ls") [[ -e "$FAKE/ls_fails" ]] && exit 1
               case "$*" in *dangling=true*) cat "$FAKE/dangling";; *) cat "$FAKE/all";; esac;;
  "volume rm") for f in all dangling; do grep -vxF "$3" "$FAKE/$f" > "$FAKE/$f.new"; mv "$FAKE/$f.new" "$FAKE/$f"; done;;
  "compose ps") cat "$FAKE/containers";;
  "info "*)    cat "$FAKE/rootdir" 2>/dev/null;;
  "inspect "*) case "$*" in
                 *.Mounts*) cat "$FAKE/mount.${!#}" 2>/dev/null;;
                 *State.Running*) echo false;;
                 *Config.Hostname*) echo "host-${!#}";;
               esac;;
  "top "*)     case "$*" in
                 *etimes*) printf 'PID ELAPSED COMMAND\n1 999 /home/runner/bin/Runner.Listener run\n';;
                 *) printf 'PID COMMAND\n1 /home/runner/bin/Runner.Listener run\n';;
               esac;;
  "rm "*)      [[ -e "$FAKE/rm_plain_fails" && "$*" != *" -f "* ]] && exit 1;;
  "image prune"|"builder prune"|"volume prune") [[ -e "$FAKE/prune_fails" ]] && exit 1;;
esac
exit 0
EOF
cat > "$T/bin/df" <<'EOF'
#!/usr/bin/env bash
[[ -e "$FAKE/df_fails" ]] && exit 1
p="$(cat "$FAKE/free_pct")"
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/fake 1000 %d %d %d%% %s\n' "$((1000 - p * 10))" "$((p * 10))" "$((100 - p))" "${!#}"
EOF
printf '#!/usr/bin/env bash\necho '"'"'{"runners":[]}'"'"'\n' > "$T/bin/curl"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/flock"
chmod +x "$T/bin/docker" "$T/bin/df" "$T/bin/curl" "$T/bin/flock"
reset() {
  rm -rf "$FAKE" "$T/state" "$T/proj/state"; mkdir -p "$FAKE"
  : > "$FAKE/all"; : > "$FAKE/dangling"; : > "$FAKE/containers"; : > "$FAKE/calls.log"
  echo "$T" > "$FAKE/rootdir"; echo 50 > "$FAKE/free_pct"
}
# shellcheck source=lib/runners.sh
. lib/runners.sh

# ---- the ledger records a runner's /var/lib/docker volume --------------------
reset
V 1 > "$FAKE/mount.c1"; V 2 > "$FAKE/mount.c2"; echo toolcache > "$FAKE/mount.c3"
printf 'c1\nc2\nc3\n' > "$FAKE/containers"
ledger_record_project; ledger_record_project
check "ledger holds c1's volume" grep -qxF "$(V 1)" "$RUNNER_LEDGER"
check "ledger holds c2's volume" grep -qxF "$(V 2)" "$RUNNER_LEDGER"
nocheck "a named volume is never ledgered" grep -q toolcache "$RUNNER_LEDGER"
check "ledger lines are unique" test "$(lines "$RUNNER_LEDGER")" = 2

# ---- the sweeper removes only ledgered, dangling volumes ---------------------
reset; mkdir -p "$T/state"
printf '%s\n' "$(V 1)" "$(V 2)" "$(V 3)" "$(V 4)" > "$FAKE/all"
printf '%s\n' "$(V 1)" "$(V 3)" "$(V 4)" > "$FAKE/dangling"           # V2 is in use
printf '%s\n' "$(V 1)" "$(V 2)" "$(V 3)" "$(V 9)" > "$RUNNER_LEDGER"    # V9 is ledgered but gone
n="$(sweep_runner_volumes 50)"
check "swept exactly the 2 ledgered dangling volumes" test "$n" = 2
check "ledgered dangling V1 removed" grep -qxF "volume rm $(V 1)" "$FAKE/calls.log"
check "ledgered dangling V3 removed" grep -qxF "volume rm $(V 3)" "$FAKE/calls.log"
nocheck "dangling but NOT ledgered V4 left alone" grep -qF "$(V 4)" "$FAKE/calls.log"
nocheck "in-use ledgered V2 left alone" grep -qxF "volume rm $(V 2)" "$FAKE/calls.log"
check "V4 still exists" grep -qxF "$(V 4)" "$FAKE/all"
check "ledger keeps only the in-use V2 (V9 was gone, V1/V3 removed)" test "$(cat "$RUNNER_LEDGER")" = "$(V 2)"
nocheck "no volume/system prune was called" grep -qE '(volume|system) prune' "$FAKE/calls.log"
nocheck "host scripts never call a blanket volume/system prune" grep -rEq 'docker (system|volume) prune' scripts lib

# ---- the sweeper caps at 50 a tick -------------------------------------------
reset; mkdir -p "$T/state"
i=100; while [[ $i -lt 160 ]]; do V "$i"; i=$((i + 1)); done > "$FAKE/all"
cp "$FAKE/all" "$FAKE/dangling"; cp "$FAKE/all" "$RUNNER_LEDGER"
n="$(sweep_runner_volumes 50)"
check "capped at 50 removals" test "$n" = 50
check "50 volume rm calls" test "$(calls 'volume rm')" = 50
check "the other 10 stay in the ledger for the next tick" test "$(lines "$RUNNER_LEDGER")" = 10
n="$(sweep_runner_volumes 50)"
check "next tick removes the remaining 10" test "$n" = 10

# ---- docker unable to list volumes: the ledger is not touched ----------------
reset; mkdir -p "$T/state"
V 1 > "$RUNNER_LEDGER"; touch "$FAKE/ls_fails"
sweep_runner_volumes 50 >/dev/null
check "ledger survives a failing docker volume ls" grep -qxF "$(V 1)" "$RUNNER_LEDGER"

# ---- docker rm carries -v ----------------------------------------------------
reset; PROJECT="$T"; export PROJECT
deregister_runner_code() { echo 204; }
V 5 > "$FAKE/mount.c1"
drain_container c1 5 >/dev/null; rc=$?
check "drain_container removed the container" test "$rc" = 0
check "docker rm carries -v" grep -qxF "rm -v c1" "$FAKE/calls.log"
nocheck "no docker rm without -v" grep -qxF "rm c1" "$FAKE/calls.log"
check "its volume was ledgered before the rm" grep -qxF "$(V 5)" "$RUNNER_LEDGER"
touch "$FAKE/rm_plain_fails"; : > "$FAKE/calls.log"
drain_container c1 5 >/dev/null
check "the forced fallback carries -v too" grep -qxF "rm -f -v c1" "$FAKE/calls.log"

# ---- the inner-dockerd prune (dind-entrypoint.sh) ----------------------------
reset
eval "$(sed -n '/^prune_inner() {/,/^}/p' dind-entrypoint.sh)"
log() { :; }
check "entrypoint prunes images >72h"  grep -qF 'prune_inner "image prune" image prune -af --filter until=72h' dind-entrypoint.sh
check "entrypoint prunes build cache >72h" grep -qF 'prune_inner "builder prune" builder prune -af --filter until=72h' dind-entrypoint.sh
check "entrypoint prunes the inner volumes" grep -qF 'prune_inner "volume prune" volume prune -af' dind-entrypoint.sh
prune_inner "volume prune" volume prune -af
check "prune_inner runs the docker command it is given" grep -qxF "volume prune -af" "$FAKE/calls.log"
touch "$FAKE/prune_fails"
prune_inner "image prune" image prune -af; rc=$?
check "a failing inner prune never aborts the entrypoint" test "$rc" = 0

# ---- the disk guard ----------------------------------------------------------
reset
echo 50 > "$FAKE/free_pct"; check "50% free is ok"   test "$(disk_level)" = "ok 50"
echo 9  > "$FAKE/free_pct"; check "9% free is low"   test "$(disk_level)" = "low 9"
echo 2  > "$FAKE/free_pct"; check "2% free is crit"  test "$(disk_level)" = "crit 2"
touch "$FAKE/df_fails";     check "unreadable disk is unknown, not blocking" test "$(disk_level)" = "unknown -"

# autoscale.sh end to end in a throwaway project copy: fake docker, no network
P="$T/proj"; mkdir -p "$P/scripts" "$P/lib"
cp scripts/autoscale.sh "$P/scripts/"; cp lib/runners.sh lib/hygiene.sh "$P/lib/"
printf 'resolve_gh_token() { GH_API_TOKEN=fake; export GH_API_TOKEN; }\n' > "$P/lib/gh-token.sh"
printf 'GH_OWNER=acme\nRUNNER_MIN=4\nRUNNER_MAX=16\nRUNNER_HEADROOM=2\n' > "$P/.env"
tick() { : > "$P/autoscale.log"; : > "$FAKE/calls.log"; env -i PATH="$PATH" HOME="$T" FAKE="$FAKE" bash "$P/scripts/autoscale.sh"; }
containers() { : > "$FAKE/containers"; i=1; while [[ $i -le $1 ]]; do echo "c$i" >> "$FAKE/containers"; i=$((i + 1)); done; }

reset; containers 0
tick; check "positive control: 50% free scales up to 4" grep -q 'compose up -d --scale runner=4' "$FAKE/calls.log"
echo 5 > "$FAKE/free_pct"
tick; nocheck "5% free: no scale-up" grep -q 'compose up' "$FAKE/calls.log"
check "5% free: DISK LOW is logged" grep -q 'DISK LOW 5% free' "$P/autoscale.log"
containers 6; rm -f "$P/.autoscale.state"
tick; check "5% free: scale-down still allowed (rm -v x2)" test "$(calls 'rm -v')" = 2
date +%s > "$P/.autoscale.state"; echo 2 > "$FAKE/free_pct"; containers 3
tick; check "2% free: drains toward 1 despite the cooldown" test "$(calls 'rm -v')" = 2
check "2% free: log says scale DOWN 3 -> 1" grep -q 'scale DOWN 3 -> 1' "$P/autoscale.log"

# the tick records ledger volumes and sweeps only ledgered dangling ones
reset; containers 4; V 7 > "$FAKE/mount.c1"
printf '%s\n' "$(V 7)" "$(V 8)" > "$FAKE/all"; V 8 > "$FAKE/dangling"   # V8: dangling, not ours
tick
check "tick ledgered the runner's volume" grep -qxF "$(V 7)" "$P/state/our-volumes.txt"
nocheck "tick left the foreign dangling V8 alone" grep -qF "volume rm $(V 8)" "$FAKE/calls.log"
V 6 >> "$P/state/our-volumes.txt"; V 6 >> "$FAKE/all"; V 6 >> "$FAKE/dangling"
tick
check "tick swept the ledgered dangling V6" grep -qxF "volume rm $(V 6)" "$FAKE/calls.log"
check "tick logged the count" grep -q 'swept 1 runner volumes' "$P/autoscale.log"

if [[ $fail -eq 0 ]]; then echo "hygiene-test: ok"; else echo "hygiene-test: FAILED"; fi
exit $fail

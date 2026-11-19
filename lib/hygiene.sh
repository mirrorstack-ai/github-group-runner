#!/usr/bin/env bash
# shellcheck shell=bash
# Disk hygiene for the SHARED host. Sourced by lib/runners.sh, so autoscale.sh
# and rollout.sh both get it. Needs docker, df, awk.
#
# THE RULE: this machine is shared with other people's containers and volumes.
# We delete a Docker object only when OUR OWN record proves it is ours: the
# ledger below lists the volume mounted at /var/lib/docker in every container
# of this compose project. Never a blanket prune on the host, never "looks
# unused, so it must be ours".
# LOCKING: the ledger functions need .autoscale.lock (autoscale.sh and rollout.sh
# hold it); without it a lost append is a leak, never an over-delete.

# One volume name per line, unique. state/ is created on demand and git-ignored.
ledger_file() { printf '%s' "${RUNNER_LEDGER:-${PROJECT:-.}/state/our-volumes.txt}"; }

# docker names an ANONYMOUS volume with 64 hex characters. A named volume
# (toolcache, gocache, anybody else's) never matches, so it can never be
# ledgered, whatever the compose file says one day.
is_anon_volume() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }

ledger_add() {
  local f n
  f="$(ledger_file)"
  mkdir -p "$(dirname "$f")" || return 1
  for n in "$@"; do
    is_anon_volume "$n" || continue
    grep -qxF -- "$n" "$f" 2>/dev/null || printf '%s\n' "$n" >> "$f"
  done
}

# Record the anonymous volume that container $1 has at /var/lib/docker.
ledger_record_container() {
  local out v
  out="$(docker inspect --format '{{range .Mounts}}{{if and (eq .Type "volume") (eq .Destination "/var/lib/docker")}}{{.Name}}{{"\n"}}{{end}}{{end}}' "$1" 2>/dev/null)" || return 0
  while IFS= read -r v; do
    [[ -n "$v" ]] && ledger_add "$v"
  done <<<"$out"
  return 0
}

# Every container of the compose project, stopped ones included (-a): a
# stopped runner still owns its volume.
ledger_record_project() {
  local cid
  while IFS= read -r cid; do
    [[ -n "$cid" ]] && ledger_record_container "$cid"
  done < <(docker compose ps -a -q runner 2>/dev/null)
  return 0
}

# Remove ledgered volumes that are dangling (no container, running or stopped,
# references them). At most $1 removals (default 50). Prints how many it removed.
#   - not in the ledger: never touched, even if dangling;
#   - in the ledger but gone from docker: dropped from the ledger;
#   - in the ledger and in use, over the cap, or `volume rm` refused: kept.
# If docker cannot list volumes the ledger is left exactly as it was.
sweep_runner_volumes() {
  local max="${1:-50}" f all dangling tmp name removed=0
  f="$(ledger_file)"
  rm -f "${f}".??????                    # temp files of a sweeper that was killed mid-run (we hold the lock)
  [[ -s "$f" ]] || { echo 0; return 0; }
  all="$(docker volume ls -q 2>/dev/null)" || { echo 0; return 1; }
  dangling="$(docker volume ls -q -f dangling=true 2>/dev/null)" || { echo 0; return 1; }
  tmp="$(mktemp "${f}.XXXXXX")" || { echo 0; return 1; }
  while IFS= read -r name || [[ -n "$name" ]]; do
    is_anon_volume "$name" || continue
    grep -qxF -- "$name" <<<"$all" || continue
    if (( removed < max )) && grep -qxF -- "$name" <<<"$dangling" \
       && docker volume rm "$name" >/dev/null 2>&1; then
      removed=$(( removed + 1 ))
      continue
    fi
    printf '%s\n' "$name" >> "$tmp"
  done < "$f"
  mv -f "$tmp" "$f" || rm -f "$tmp"
  echo "$removed"
}

# Integer percent of the Docker root's filesystem that is free; fails when
# neither it nor / can be read.
disk_free_pct() {
  local root p
  root="$(docker info -f '{{.DockerRootDir}}' 2>/dev/null)"
  for p in "$root" /; do
    [[ -n "$p" && -d "$p" ]] || continue
    df -P "$p" 2>/dev/null \
      | awk 'NR==2 && $3+$4>0 {printf "%d\n", $4*100/($3+$4); ok=1} END {exit !ok}' && return 0
  done
  return 1
}

# Prints "<ok|low|crit|unknown> <free%>". low = under DISK_MIN_FREE_PCT
# (default 10), crit = under DISK_CRIT_FREE_PCT (default 3). An unreadable
# disk is "unknown" and never blocks the pool.
disk_level() {
  local free min="${DISK_MIN_FREE_PCT:-10}" crit="${DISK_CRIT_FREE_PCT:-3}"
  free="$(disk_free_pct)" || { echo "unknown -"; return 0; }
  if (( free < crit )); then echo "crit ${free}"
  elif (( free < min )); then echo "low ${free}"
  else echo "ok ${free}"
  fi
}

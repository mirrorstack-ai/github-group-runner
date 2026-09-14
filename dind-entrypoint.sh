#!/usr/bin/env bash
# Runs as root. Brings up a dockerd private to THIS container, then hands off to
# entrypoint.sh as the unprivileged runner user.
#
# Why a real daemon and not the host socket: GitHub Actions `services:` publish
# ports and the job — which runs directly on the runner, not inside a
# `container:` — reaches them over localhost. Service containers must therefore
# live in this container's network namespace.
set -euo pipefail

log() { printf '[dind] %s\n' "$*"; }

DOCKERD_ENABLED="${RUNNER_ENABLE_DIND:-true}"
DOCKERD_TIMEOUT="${DOCKERD_TIMEOUT:-60}"

drop_to_runner() {
  # Stage the app key FIRST. This must live here, not further down: when
  # RUNNER_ENABLE_DIND=false we jump straight to this function, and a key left
  # owned by root would be unreadable to uid 1001 — no runner would register.
  if [[ -n "${GH_APP_PRIVATE_KEY:-}" && -r "${GH_APP_PRIVATE_KEY}" \
        && "${GH_APP_PRIVATE_KEY}" != "/home/runner/.gh-app-key.pem" ]]; then
    install -o 1001 -g 1001 -m 600 "${GH_APP_PRIVATE_KEY}" /home/runner/.gh-app-key.pem
    export GH_APP_PRIVATE_KEY=/home/runner/.gh-app-key.pem
    log "app key staged for uid 1001 (mode 600)"
  fi

  # setpriv execs, so entrypoint.sh becomes PID 1 and Docker's SIGTERM reaches
  # its deregistration trap directly. HOME/USER/LOGNAME must be set explicitly:
  # setpriv changes the uid but keeps the environment, so root's HOME=/root
  # would follow the runner in and actions/checkout dies on /root/.gitconfig.
  exec env \
    HOME=/home/runner \
    USER=runner \
    LOGNAME=runner \
    setpriv --reuid=1001 --regid=1001 --init-groups /usr/local/bin/entrypoint.sh
}

if [[ "${DOCKERD_ENABLED}" != "true" ]]; then
  log "RUNNER_ENABLE_DIND=${DOCKERD_ENABLED} — skipping dockerd"
  drop_to_runner
fi

if [[ ! -w /var/lib/docker ]]; then
  log "WARNING: /var/lib/docker is not writable; dockerd will likely fail"
fi

log "starting dockerd (storage-driver=overlay2)"

# Stagger: several dockerds initialising at once contend on the kernel's
# xtables lock and on bridge/netfilter setup. A short per-container offset
# derived from the hostname keeps them from colliding on a cold `up -d`.
STAGGER=$(( 0x$(hostname | tail -c 3 | tr -dc '0-9a-f' | head -c 2) % 15 ))
[[ "${STAGGER}" -gt 0 ]] && { log "staggering start by ${STAGGER}s"; sleep "${STAGGER}"; }

start_dockerd() {
  : > /var/log/dockerd.log
  dockerd \
    --host=unix:///var/run/docker.sock \
    --group=docker \
    --storage-driver=overlay2 \
    --iptables=true \
    --ip6tables=false \
    >>/var/log/dockerd.log 2>&1 &
  DOCKERD_PID=$!
}

DOCKERD_ATTEMPTS="${DOCKERD_ATTEMPTS:-5}"
for ((attempt = 1; attempt <= DOCKERD_ATTEMPTS; attempt++)); do
  # An ephemeral runner exits after each job and `restart: always` brings the
  # SAME container back — same filesystem, so dockerd's pidfile and socket
  # survive. dockerd then refuses to start ("process with PID N is still
  # running"). This only bites AFTER the first job, so a fresh `up` looks fine.
  rm -f /var/run/docker.pid /var/run/docker.sock
  start_dockerd
  ready=0
  for ((i = 0; i < DOCKERD_TIMEOUT; i++)); do
    if ! kill -0 "${DOCKERD_PID}" 2>/dev/null; then
      wait "${DOCKERD_PID}" 2>/dev/null; rc=$?
      log "attempt ${attempt}/${DOCKERD_ATTEMPTS}: dockerd exited rc=${rc}"
      if [[ -s /var/log/dockerd.log ]]; then
        log "--- dockerd.log ---"; tail -40 /var/log/dockerd.log >&2
      else
        log "dockerd.log EMPTY — died before logging (check host dmesg for OOM/seccomp)"
      fi
      break
    fi
    if docker version --format '{{.Server.APIVersion}}' >/dev/null 2>&1; then
      log "dockerd ready after ${i}s (attempt ${attempt}) — server API $(docker version --format '{{.Server.APIVersion}}')"
      ready=1; break
    fi
    sleep 1
  done
  [[ "${ready}" -eq 1 ]] && break
  backoff=$(( attempt * 5 ))
  log "retrying in ${backoff}s"
  sleep "${backoff}"
done

if ! docker version --format '{{.Server.APIVersion}}' >/dev/null 2>&1; then
  log "ERROR: dockerd never became ready after ${DOCKERD_ATTEMPTS} attempts"
  [[ -s /var/log/dockerd.log ]] && tail -40 /var/log/dockerd.log >&2
  exit 1
fi

# /var/lib/docker is a persistent volume, so the previous job's service
# containers and networks are still sitting there after a restart. Clear them so
# each job starts clean and stale port bindings can't collide. Images are kept —
# they're the only cache these ephemeral runners get.
docker container prune -f >/dev/null 2>&1 || true
docker network prune -f >/dev/null 2>&1 || true

# Prove the exact thing `services:` jobs need: a published port reachable on
# localhost from this namespace. Worth enabling for your first DGX boot.
if [[ "${DIND_SELFTEST:-false}" == "true" ]]; then
  log "self-test: publishing a container port and dialling localhost"
  if docker run --rm -d --name dind-selftest -p 39999:80 nginx:alpine >/dev/null 2>&1; then
    for ((i = 0; i < 20; i++)); do
      if curl -sf -o /dev/null http://localhost:39999; then log "self-test OK"; break; fi
      sleep 1
    done
    docker rm -f dind-selftest >/dev/null 2>&1 || true
  else
    log "self-test skipped (could not pull nginx:alpine)"
  fi
fi

log "handing off to the runner as uid 1001"
drop_to_runner

#!/usr/bin/env bash
# Registers one ephemeral runner, runs it, and deregisters on the way out.
# Ephemeral means: the runner accepts exactly one job, then exits. Compose's
# restart policy brings the container back, which re-registers fresh.
set -euo pipefail

log() { printf '[entrypoint] %s\n' "$*"; }
die() { printf '[entrypoint] ERROR: %s\n' "$*" >&2; exit 1; }

: "${GH_OWNER:?GH_OWNER is required (org login, or user for a repo-scoped runner)}"

# shellcheck source=lib/gh-token.sh
. /usr/local/lib/gh-token.sh
# shellcheck source=lib/scrub.sh
. /usr/local/lib/scrub.sh

RUNNER_SCOPE="${RUNNER_SCOPE:-org}"
RUNNER_GROUP="${RUNNER_GROUP:-Default}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,Linux,ARM64}"
RUNNER_NAME_PREFIX="${RUNNER_NAME_PREFIX:-runner}"
RUNNER_WORKDIR="${RUNNER_WORKDIR:-/home/runner/_work}"
GITHUB_API="${GITHUB_API:-https://api.github.com}"
GITHUB_HOST="${GITHUB_HOST:-https://github.com}"

# $(hostname) is the container ID inside compose, so names stay unique across
# replicas and across restarts. THIS is what stops a dead runner's name from
# being permanently unusable — see dgx-spark-3.
RUNNER_NAME="${RUNNER_NAME:-${RUNNER_NAME_PREFIX}-$(hostname)}"

case "${RUNNER_SCOPE}" in
  org)
    TOKEN_PATH="orgs/${GH_OWNER}/actions/runners/registration-token"
    RUNNER_URL="${GITHUB_HOST}/${GH_OWNER}"
    ;;
  repo)
    : "${GH_REPO:?GH_REPO is required when RUNNER_SCOPE=repo}"
    TOKEN_PATH="repos/${GH_OWNER}/${GH_REPO}/actions/runners/registration-token"
    RUNNER_URL="${GITHUB_HOST}/${GH_OWNER}/${GH_REPO}"
    ;;
  *)
    die "RUNNER_SCOPE must be 'org' or 'repo' (got '${RUNNER_SCOPE}')"
    ;;
esac

# Runner groups are an org/enterprise concept; a repo-scoped runner has none.
if [[ "${RUNNER_SCOPE}" == "repo" && "${RUNNER_GROUP}" != "Default" ]]; then
  log "WARNING: RUNNER_GROUP='${RUNNER_GROUP}' is ignored for repo-scoped runners"
  RUNNER_GROUP="Default"
fi

fetch_token() {
  local path="$1" body http_code
  # Re-resolve each call: an app installation token can expire between a
  # container's registration and its eventual deregistration.
  resolve_gh_token "${GH_OWNER}" >&2 || die "could not obtain GitHub credentials"
  body="$(curl -sS -w '\n%{http_code}' -X POST \
      -H "Authorization: Bearer ${GH_API_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "${GITHUB_API}/${path}")" || die "network failure calling ${path}"
  http_code="$(tail -n1 <<<"${body}")"
  body="$(sed '$d' <<<"${body}")"
  if [[ "${http_code}" != "201" ]]; then
    [[ "${http_code}" == "403" ]] && \
      log "hint: granted permissions were [${GH_APP_PERMS:-n/a}] — needs organization_self_hosted_runners=write"
    die "POST /${path} returned ${http_code}: $(jq -r '.message // .' <<<"${body}" 2>/dev/null || echo "${body}")"
  fi
  jq -er '.token' <<<"${body}" || die "no .token in response from /${path}"
}

cleanup() {
  # Deregistration moved to the HOST (scripts/autoscale.sh and scripts/rollout.sh
  # delete the registration by runner name right after removing a container):
  # this container scrubs its credentials as soon as config.sh has run, so it
  # has nothing left to call the API with. An ephemeral runner that ran its job
  # is removed by GitHub itself; a stale entry is taken over by --replace on the
  # next start under the same name.
  log "exiting ${RUNNER_NAME} (deregistration is the host's job)"
}

cd /home/runner

if [[ "${RUNNER_REGISTERED:-}" != "1" ]]; then
  log "scope=${RUNNER_SCOPE} url=${RUNNER_URL} group=${RUNNER_GROUP} name=${RUNNER_NAME}"
  log "requesting registration token"
  resolve_gh_token "${GH_OWNER}" || die "could not obtain GitHub credentials"
  log "auth mode: ${GH_AUTH_MODE}"
  REG_TOKEN="$(fetch_token "${TOKEN_PATH}")"

  CONFIG_ARGS=(
    --url "${RUNNER_URL}"
    --token "${REG_TOKEN}"
    --name "${RUNNER_NAME}"
    --labels "${RUNNER_LABELS}"
    --work "${RUNNER_WORKDIR}"
    --unattended
    --replace          # take over a stale registration instead of erroring out
    --disableupdate
  )
  [[ "${RUNNER_SCOPE}" == "org" ]] && CONFIG_ARGS+=(--runnergroup "${RUNNER_GROUP}")
  [[ "${RUNNER_EPHEMERAL:-true}" == "true" ]] && CONFIG_ARGS+=(--ephemeral)

  ./config.sh "${CONFIG_ARGS[@]}"
  unset REG_TOKEN

  # Registration is the last thing that needs a credential. Everything from
  # here on — every job step included — runs as this uid in this container, so
  # delete the staged key and drop the token from the environment (core-v2#1503).
  scrub_credentials
  # Then re-exec: `unset` edits bash's own table, but the block the kernel shows
  # in /proc/1/environ (readable by uid 1001) is the one exec handed us, which
  # in PAT mode held GH_TOKEN. A fresh exec rebuilds it from the scrubbed set.
  exec env RUNNER_REGISTERED=1 "$0"
fi

# ---- second pass: no credential exists in this process any more -------------
RUNNER_PID=""
term_handler() {
  log "signal received — asking the runner to finish and exit"
  [[ -n "${RUNNER_PID}" ]] && kill -TERM "${RUNNER_PID}" 2>/dev/null || true
}
trap term_handler INT TERM
trap cleanup EXIT

# exec'ing run.sh would bypass the traps, so background it and wait.
./run.sh &
RUNNER_PID=$!
wait "${RUNNER_PID}" || true

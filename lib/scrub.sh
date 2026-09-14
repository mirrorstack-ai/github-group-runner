#!/usr/bin/env bash
# scrub_credentials — delete the staged GitHub App key and drop every GitHub
# credential from the environment, then prove both are gone. Called by
# entrypoint.sh right after `config.sh` succeeds: nothing after registration
# needs a credential, and everything after it — every job step included — runs
# as the same uid in the same container (core-v2#1503).
#
# Sourced, not executed: it must unset variables in the CALLER's shell.
# Needs `log` and `die` from the caller. Unit test: tests/scrub-test.sh.

GH_CREDENTIAL_VARS="GH_API_TOKEN GH_AUTH_MODE GH_APP_PERMS GH_APP_ID GH_APP_PRIVATE_KEY GH_APP_PRIVATE_KEY_B64 GH_TOKEN"

scrub_credentials() {
  local key="${GH_APP_PRIVATE_KEY:-}" staged="${SCRUB_STAGED_KEY:-/home/runner/.gh-app-key.pem}" f v left=""
  # Delete only a regular file we own that is not a mount: the staged copy, or
  # the file the B64 path wrote. Never the (read-only, root) bind mount itself.
  for f in "${key}" "${staged}"; do
    [[ -n "${f}" && -f "${f}" && -O "${f}" ]] || continue
    mountpoint -q "${f}" 2>/dev/null && continue
    rm -f "${f}" && log "deleted ${f}"
  done
  # shellcheck disable=SC2086
  unset ${GH_CREDENTIAL_VARS}
  # Prove it. A scrub that silently left something behind is worse than none.
  [[ -e "${staged}" ]] && left="${staged} still exists"
  [[ -n "${key}" && -e "${key}" && -O "${key}" ]] && left="${left:+${left}; }${key} still exists"
  for v in ${GH_CREDENTIAL_VARS}; do
    [[ -n "${!v:-}" ]] && left="${left:+${left}; }${v} still set"
  done
  if [[ -n "${left}" ]]; then
    die "credential scrub incomplete: ${left} (core-v2#1503)"
    return 1
  fi
  log "credentials scrubbed: no key file, no GH_* credential in the environment"
}

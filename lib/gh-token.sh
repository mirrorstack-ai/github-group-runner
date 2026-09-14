# shellcheck shell=bash
# Resolves GitHub credentials into $GH_API_TOKEN.
#
# Two modes, auto-detected:
#   GitHub App  — GH_APP_ID + GH_APP_PRIVATE_KEY  (preferred)
#   PAT         — GH_TOKEN
#
# App mode signs a short-lived RS256 JWT, exchanges it for the org's
# installation token, and returns that. Installation tokens live 1 hour, which
# is fine: every container mints its own at startup and ephemeral containers
# restart constantly. Nothing long-lived is ever stored.
#
# Sourced by entrypoint.sh (in-container) and by scripts/*.sh (on the host).

_b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

_gh_api_raw() {
  # $1 = bearer token, rest = curl args.
  # Echoes the body followed by a final line holding the HTTP status. Callers
  # split it themselves — an out-param would be assigned inside the caller's
  # command substitution (a subshell) and never make it back.
  local token="$1"; shift
  curl -sS -w '\n%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" "$@"
}

_app_jwt() {
  local app_id="$1" key="$2" now header payload h p sig
  now="$(date +%s)"
  # iat backdated 60s to tolerate clock skew. exp is now+480 so that exp-iat is
  # 540s — GitHub rejects anything over 600, and landing exactly on the cap
  # leaves no room for the skew allowance above.
  header='{"alg":"RS256","typ":"JWT"}'
  payload="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 480))" "${app_id}")"
  h="$(printf '%s' "${header}" | _b64url)"
  p="$(printf '%s' "${payload}" | _b64url)"
  sig="$(printf '%s' "${h}.${p}" | openssl dgst -sha256 -sign "${key}" -binary | _b64url)" \
    || { echo "failed to sign JWT — is ${key} a valid RSA private key?" >&2; return 1; }
  printf '%s.%s.%s' "${h}" "${p}" "${sig}"
}

# resolve_gh_token <org>  → sets GH_API_TOKEN
resolve_gh_token() {
  local org="$1" jwt inst_id resp code body

  # B64 mode is a macOS/OrbStack workaround (bind-mounting the .pem there hangs
  # the container). On Linux leave GH_APP_PRIVATE_KEY_B64 empty and use the file.
  if [[ -n "${GH_APP_ID:-}" && -n "${GH_APP_PRIVATE_KEY_B64:-}" ]]; then
    GH_APP_PRIVATE_KEY="${GH_APP_KEY_TMP:-/home/runner/.gh-app-key.pem}"
    ( umask 077; printf '%s' "${GH_APP_PRIVATE_KEY_B64}" | base64 -d > "${GH_APP_PRIVATE_KEY}" ) \
      || { echo "GH_APP_PRIVATE_KEY_B64 is not valid base64" >&2; return 1; }
  fi

  if [[ -n "${GH_APP_ID:-}" && -n "${GH_APP_PRIVATE_KEY:-}" ]]; then
    [[ -r "${GH_APP_PRIVATE_KEY}" ]] \
      || { echo "GH_APP_PRIVATE_KEY not readable: ${GH_APP_PRIVATE_KEY}" >&2; return 1; }

    jwt="$(_app_jwt "${GH_APP_ID}" "${GH_APP_PRIVATE_KEY}")" || return 1

    resp="$(_gh_api_raw "${jwt}" "${GITHUB_API:-https://api.github.com}/orgs/${org}/installation")" || return 1
    code="$(tail -n1 <<<"${resp}")"; body="$(sed '$d' <<<"${resp}")"
    if [[ "${code}" != "200" ]]; then
      echo "cannot find app installation on '${org}' (HTTP ${code}): $(jq -r '.message // .' <<<"${body}")" >&2
      [[ "${code}" == "404" ]] && echo "  → the app exists but is not installed on ${org}, or GH_APP_ID is wrong" >&2
      [[ "${code}" == "401" ]] && echo "  → JWT rejected: GH_APP_ID and the private key don't belong to the same app, or host clock is skewed" >&2
      return 1
    fi
    inst_id="$(jq -er '.id' <<<"${body}")" || return 1

    resp="$(_gh_api_raw "${jwt}" -X POST \
      "${GITHUB_API:-https://api.github.com}/app/installations/${inst_id}/access_tokens")" || return 1
    code="$(tail -n1 <<<"${resp}")"; body="$(sed '$d' <<<"${resp}")"
    if [[ "${code}" != "201" ]]; then
      echo "cannot mint installation token (HTTP ${code}): $(jq -r '.message // .' <<<"${body}")" >&2
      return 1
    fi

    GH_API_TOKEN="$(jq -er '.token' <<<"${body}")" || return 1
    GH_AUTH_MODE="app (installation ${inst_id})"
    # Surface what the installation actually granted — a missing
    # organization_self_hosted_runners here is the #1 cause of later 403s.
    GH_APP_PERMS="$(jq -r '.permissions | to_entries | map("\(.key)=\(.value)") | join(" ")' <<<"${body}")"
    export GH_API_TOKEN GH_AUTH_MODE GH_APP_PERMS
    return 0
  fi

  if [[ -n "${GH_TOKEN:-}" ]]; then
    GH_API_TOKEN="${GH_TOKEN}"
    GH_AUTH_MODE="pat"
    export GH_API_TOKEN GH_AUTH_MODE
    return 0
  fi

  echo "no credentials: set GH_APP_ID + GH_APP_PRIVATE_KEY (preferred), or GH_TOKEN" >&2
  return 1
}

#!/usr/bin/env bash
# Unit test for lib/scrub.sh: with a fake staged key and every credential
# variable set, scrub_credentials must delete the file, unset the variables,
# leave nothing for a child process to inherit — and refuse to pass when the
# file cannot be deleted. Runs anywhere with bash; CI runs it on ubuntu-latest.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
log() { :; }
die() { echo "  die: $*"; return 99; }   # never exit the test; the scrub must not reach it on the happy path
T="$(mktemp -d)"; trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
fail=0
CREDS="GH_API_TOKEN GH_AUTH_MODE GH_APP_PERMS GH_APP_ID GH_APP_PRIVATE_KEY GH_APP_PRIVATE_KEY_B64 GH_TOKEN"

# shellcheck source=lib/scrub.sh
. lib/scrub.sh

# --- happy path: staged key + every variable, exported as the entrypoint has them
printf 'not-a-real-key\n' > "$T/staged.pem"
export GH_APP_PRIVATE_KEY="$T/staged.pem" GH_API_TOKEN=ghs_fake GH_APP_ID=1 GH_TOKEN=ghp_fake \
       GH_APP_PRIVATE_KEY_B64=Zm9v GH_AUTH_MODE=app GH_APP_PERMS=x
SCRUB_STAGED_KEY="$T/staged.pem"
scrub_credentials; rc=$?
[[ $rc -eq 0 ]] || { echo "FAIL: scrub returned $rc on the happy path"; fail=1; }
[[ -e "$T/staged.pem" ]] && { echo "FAIL: key file survived"; fail=1; }
for v in $CREDS; do
  [[ -n "${!v:-}" ]] && { echo "FAIL: $v survived in the shell"; fail=1; }
done
# what a child process — a job step — would inherit is the property that matters
if env | grep -qE '^(GH_API_TOKEN|GH_TOKEN|GH_APP_PRIVATE_KEY(_B64)?|GH_APP_ID|GH_APP_PERMS|GH_AUTH_MODE)='; then
  echo "FAIL: a child process would still inherit a credential"; fail=1
fi

# --- the scrub must refuse when the key cannot be removed
mkdir "$T/ro"; printf 'k\n' > "$T/ro/key.pem"; chmod 500 "$T/ro"
if [[ "$(id -u)" -eq 0 ]]; then
  echo "skip: running as root, the read-only directory case cannot be exercised"
else
  export GH_APP_PRIVATE_KEY="$T/ro/key.pem"; SCRUB_STAGED_KEY="$T/ro/key.pem"
  scrub_credentials >/dev/null 2>&1; rc=$?
  chmod 700 "$T/ro"
  [[ $rc -eq 0 ]] && { echo "FAIL: scrub passed although the key could not be deleted"; fail=1; }
fi

# --- a bind-mount-like path we do not own is never deleted (simulate: not owner)
# (cannot chown without root; covered by the -O test in the function — documented, not tested here)

if [[ $fail -eq 0 ]]; then echo "scrub-test: ok"; else echo "scrub-test: FAILED"; fi
exit $fail

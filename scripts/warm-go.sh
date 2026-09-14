#!/usr/bin/env bash
# Pre-extract Go toolchains into the shared tool cache so actions/setup-go finds
# them and never downloads (T63). Run on the host after `scripts/rollout.sh`
# has created the `toolcache` volume, and again whenever a workflow starts
# resolving a new patch version (setup-go logs "Attempting to download X").
#
#   scripts/warm-go.sh 1.26.8 1.25.0        # exact versions, as setup-go resolves them
#
# Layout setup-go expects (actions/tool-cache): <RUNNER_TOOL_CACHE>/go/<semver>/arm64/
# holding the tarball's go/ contents, plus <semver>/arm64.complete. A version
# spec like "1.26" resolves to the newest 1.26.x in setup-go's manifest, so warm
# the exact patch, not the minor. Idempotent: a version with its .complete marker
# is skipped. Uses the runner image itself for curl + tar; runs as root inside a
# one-off container and hands the result to uid 1001.
set -uo pipefail
PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$PROJECT" || exit 1
[[ $# -ge 1 ]] || { echo "usage: $0 <go-version> [<go-version> ...]   e.g. $0 1.26.8 1.25.0"; exit 2; }

IMAGE="$(docker compose config --format json 2>/dev/null | jq -r '.services.runner.image // "gh-runner-dgx:local"')"
VOLUME="$(docker compose config --format json 2>/dev/null | jq -r '.volumes.toolcache.name // "gh-runners-dgx_toolcache"')"
docker volume inspect "$VOLUME" >/dev/null 2>&1 || { echo "volume $VOLUME does not exist yet — run scripts/rollout.sh first"; exit 1; }

docker run --rm --entrypoint sh -u 0 -v "${VOLUME}:/tool" "$IMAGE" -c '
set -eu
for v in "$@"; do
  if [ -f "/tool/go/$v/arm64.complete" ]; then echo "go $v: already warm"; continue; fi
  echo "go $v: downloading"
  rm -rf "/tmp/go-$v" && mkdir -p "/tmp/go-$v"
  curl -fsSL "https://go.dev/dl/go$v.linux-arm64.tar.gz" | tar -xz -C "/tmp/go-$v"
  mkdir -p "/tool/go/$v"
  rm -rf "/tool/go/$v/arm64"
  mv "/tmp/go-$v/go" "/tool/go/$v/arm64"
  touch "/tool/go/$v/arm64.complete"
  chown -R 1001:1001 "/tool/go/$v"
  echo "go $v: ready ($(/tool/go/$v/arm64/bin/go version))"
done
chown 1001:1001 /tool /tool/go
ls -la /tool/go
' _ "$@"

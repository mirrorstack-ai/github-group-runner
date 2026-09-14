# syntax=docker/dockerfile:1
#
# GitHub Actions self-hosted runner — linux/arm64.
# Runs one ephemeral runner per container; docker compose scales it to N.

FROM ubuntu:24.04

# Pinned in one place. Bump RUNNER_VERSION + RUNNER_SHA256 together — the
# checksum comes from the release notes of https://github.com/actions/runner/releases
ARG RUNNER_VERSION=2.336.0
ARG RUNNER_SHA256=58b758e420b87093fbd4bfddd368074960053e2f1388f01848c82624b90f27d1
ARG DOCKER_CLI_VERSION=28.5.2

# RUNNER_MANUALLY_TRAP_SIG stops run.sh installing its own signal handlers, so
# entrypoint.sh's trap is the one that runs and deregistration actually happens.
ENV DEBIAN_FRONTEND=noninteractive \
    RUNNER_MANUALLY_TRAP_SIG=1

# Base deps. libicu74 + libssl3 are what the runner's .NET host needs;
# the rest is the minimum most workflows assume exists.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget git jq sudo unzip zip tar gzip xz-utils openssl \
        build-essential libicu74 libssl3 liblttng-ust1t64 libkrb5-3 zlib1g \
        openssh-client gnupg tzdata locales python3 python3-venv python3-pip \
        postgresql-client \
        `# dockerd's own runtime needs: netfilter for port publishing, and` \
        `# uidmap/fuse-overlayfs for container storage` \
        iptables iproute2 uidmap fuse-overlayfs xfsprogs kmod \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI. Preinstalled on GitHub-hosted images, so workflows assume it and
# never install it themselves — without it they die with `gh: command not found`
# (exit 127). Not in Ubuntu's default repos, so use GitHub's apt repo.
# arch is read from dpkg, NOT hardcoded: these runners are arm64 and an amd64
# pin would resolve to nothing installable.
RUN mkdir -p -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
         -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
         > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/* \
    && gh --version

# AWS CLI v2 — deploy-aws.yml runs `aws lambda invoke` for the migrate step, and
# publish.yml in api-platform / web-account / web-applications uses it too.
# No setup-action supplies it, unlike node/go/pnpm/rust/tofu which do.
# aarch64, NOT x86_64: the wrong bundle installs a binary that cannot execute.
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/awscliv2.zip /tmp/aws \
    && aws --version

# Full Docker engine, not just the CLI. GitHub Actions `services:` need a real
# daemon *inside this container*: the job runs directly on the runner and talks
# to services over localhost, so service containers must publish into this
# container's own network namespace.
RUN curl -fsSL "https://download.docker.com/linux/static/stable/aarch64/docker-${DOCKER_CLI_VERSION}.tgz" \
        -o /tmp/docker.tgz \
    && tar -xzf /tmp/docker.tgz -C /tmp \
    && mv /tmp/docker/* /usr/local/bin/ \
    && rm -rf /tmp/docker /tmp/docker.tgz \
    && docker --version && dockerd --version && runc --version | head -1

# ubuntu:24.04 already ships a uid-1000 "ubuntu" user; take 1001 instead.
# The docker group is what lets the unprivileged runner reach the daemon socket
# that dockerd (running as root) creates with --group docker.
RUN groupadd -g 2375 docker \
    && useradd -m -u 1001 -s /bin/bash -G docker runner \
    && echo 'runner ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/runner \
    && chmod 0440 /etc/sudoers.d/runner

WORKDIR /home/runner

# Runner.Listener refuses to start as root, so install as the runner user.
USER runner
RUN curl -fsSL "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-arm64-${RUNNER_VERSION}.tar.gz" \
        -o /tmp/runner.tar.gz \
    && echo "${RUNNER_SHA256}  /tmp/runner.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/runner.tar.gz -C /home/runner \
    && rm /tmp/runner.tar.gz

# installdependencies.sh needs root; the runner itself does not.
USER root
RUN /home/runner/bin/installdependencies.sh && rm -rf /var/lib/apt/lists/*

COPY --chown=root:root --chmod=0644 lib/gh-token.sh        /usr/local/lib/gh-token.sh
COPY --chown=root:root --chmod=0755 entrypoint.sh          /usr/local/bin/entrypoint.sh
COPY --chown=root:root --chmod=0755 dind-entrypoint.sh     /usr/local/bin/dind-entrypoint.sh

# /var/lib/docker must be a real volume: overlay2 cannot stack on the
# container's own overlayfs. compose gives each replica its own anonymous one.
VOLUME /var/lib/docker

# Starts as root to launch dockerd, then drops to the runner user via setpriv
# (which execs, so the runner process stays PID 1 and keeps receiving SIGTERM).
USER root
ENV RUNNER_ALLOW_RUNASROOT=0
ENTRYPOINT ["/usr/local/bin/dind-entrypoint.sh"]

# Orca server image — headless coding-agent cockpit.
# All version pins are load-bearing: Orca releases ~daily with breaking changes.
FROM ubuntu:24.04

ARG ORCA_VERSION=1.4.188
ARG CLAUDE_CODE_VERSION=2.1.235
ARG CODEX_VERSION=0.148.0
ARG NODE_MAJOR=22

LABEL org.opencontainers.image.source="https://github.com/Mershab99/devex" \
      dev.mershab.orca-version="${ORCA_VERSION}" \
      dev.mershab.claude-code-version="${CLAUDE_CODE_VERSION}" \
      dev.mershab.codex-version="${CODEX_VERSION}"

ENV DEBIAN_FRONTEND=noninteractive

# Base tooling + headless display stack. Orca auto-starts Xvfb on :99 when DISPLAY is unset.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl file jq git openssh-client xvfb zlib1g-dev gnupg \
    && rm -rf /var/lib/apt/lists/*

# Node for the agent CLIs (pinned major via nodesource)
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" "@openai/codex@${CODEX_VERSION}"

# Orca .deb. docs/decisions.md #3 assumed apt would resolve the Electron dependency set from
# the deb's own Depends — it does not. Upstream's Depends (python3, python3-gi, gir1.2-atspi-2.0,
# at-spi2-core, xdotool, xclip, xvfb) names none of the Chromium shared libraries, so the binary
# installs cleanly and then dies with "libnspr4.so: cannot open shared object file". These are the
# packages providing the 13 sonames `ldd /opt/Orca/orca-ide` reports missing, plus libgbm1 which
# Chromium dlopens. Arch-independent — amd64 fails identically.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libnspr4 libnss3 libatk1.0-0t64 libatk-bridge2.0-0t64 libcups2t64 \
        libgtk-3-0t64 libpango-1.0-0 libxcomposite1 libxdamage1 libxfixes3 \
        libasound2t64 libgbm1 \
    && rm -rf /var/lib/apt/lists/*

# TARGETARCH is buildx-provided and its values (amd64/arm64) match the deb suffixes exactly,
# so this is a plain substitution — no arch case statement. Upstream ships both.
ARG TARGETARCH
RUN curl -fsSL -o /tmp/orca.deb \
        "https://github.com/stablyai/orca/releases/download/v${ORCA_VERSION}/orca-ide_${ORCA_VERSION}_${TARGETARCH}.deb" \
    && apt-get update && apt-get install -y --no-install-recommends /tmp/orca.deb \
    && rm -f /tmp/orca.deb && rm -rf /var/lib/apt/lists/*

# Non-root runtime user; $HOME lives on the PVC (agent OAuth state, Orca config, worktrees).
# Orca binary stays root-owned read-only (Chromium sandbox requirement).
RUN userdel -r ubuntu 2>/dev/null || true \
    && useradd --uid 1000 --create-home --home-dir /data --shell /bin/bash orca

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

USER orca
ENV HOME=/data \
    LIBGL_ALWAYS_SOFTWARE=1
WORKDIR /data
EXPOSE 6768

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

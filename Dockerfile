FROM mcr.microsoft.com/devcontainers/base:ubuntu-22.04

ARG TASK_VERSION=3.40.1
ARG FLUX_VERSION=2.4.0
ARG CLUSTERCTL_VERSION=1.9.0
ARG SVELTOS_VERSION=4.2.0
ARG SOPS_VERSION=3.9.2
ARG AGE_VERSION=1.2.0
ARG K9S_VERSION=0.32.7
ARG YQ_VERSION=4.44.6

# System packages: image building, virtualization, networking tools
RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
    && apt-get install -y --no-install-recommends \
        # Image build tools
        qemu-utils \
        libguestfs-tools \
        linux-image-generic \
        # General utilities
        ca-certificates \
        curl \
        git \
        gnupg \
        jq \
        make \
        openssh-client \
        python3 \
        python3-pip \
        unzip \
        wget \
        xz-utils \
        zsh \
        # Network utilities
        dnsutils \
        iputils-ping \
        iproute2 \
        nmap \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Task (taskfile.dev)
RUN curl -fsSL "https://github.com/go-task/task/releases/download/v${TASK_VERSION}/task_linux_amd64.tar.gz" \
    | tar -xz -C /usr/local/bin task

# Flux CLI
RUN curl -fsSL "https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}/flux_${FLUX_VERSION}_linux_amd64.tar.gz" \
    | tar -xz -C /usr/local/bin flux

# clusterctl (CAPI CLI)
RUN curl -fsSL -o /usr/local/bin/clusterctl \
    "https://github.com/kubernetes-sigs/cluster-api/releases/download/v${CLUSTERCTL_VERSION}/clusterctl-linux-amd64" \
    && chmod +x /usr/local/bin/clusterctl

# sveltosctl
RUN curl -fsSL -o /usr/local/bin/sveltosctl \
    "https://github.com/projectsveltos/sveltosctl/releases/download/v${SVELTOS_VERSION}/sveltosctl_linux_amd64" \
    && chmod +x /usr/local/bin/sveltosctl

# SOPS (secret encryption)
RUN curl -fsSL -o /usr/local/bin/sops \
    "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.amd64" \
    && chmod +x /usr/local/bin/sops

# age (encryption backend for SOPS)
RUN curl -fsSL "https://github.com/FiloSottile/age/releases/download/v${AGE_VERSION}/age-v${AGE_VERSION}-linux-amd64.tar.gz" \
    | tar -xz -C /usr/local/bin --strip-components=1 age/age age/age-keygen

# k9s (TUI cluster manager)
RUN curl -fsSL "https://github.com/derailed/k9s/releases/download/v${K9S_VERSION}/k9s_Linux_amd64.tar.gz" \
    | tar -xz -C /usr/local/bin k9s

# yq (YAML processor)
RUN curl -fsSL -o /usr/local/bin/yq \
    "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64" \
    && chmod +x /usr/local/bin/yq

# ipmitool (BMC management)
RUN apt-get update && apt-get install -y --no-install-recommends ipmitool \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Set zsh as default for vscode user
USER vscode
RUN sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended \
    && echo 'export PATH=$HOME/.local/bin:$PATH' >> ~/.zshrc

USER root

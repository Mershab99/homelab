FROM mcr.microsoft.com/devcontainers/base:ubuntu-22.04

ARG TASK_VERSION=3.40.1
ARG FLUX_VERSION=2.4.0
ARG CLUSTERCTL_VERSION=1.9.0
ARG TALOS_VERSION=1.9.1
ARG SOPS_VERSION=3.9.2
ARG AGE_VERSION=1.2.0
ARG K9S_VERSION=0.32.7
ARG YQ_VERSION=4.44.6
ARG KUSTOMIZE_VERSION=5.5.0
ARG KUBECONFORM_VERSION=0.6.7
ARG GITLEAKS_VERSION=8.21.2
ARG ORAS_VERSION=1.2.0
ARG KYVERNO_VERSION=1.13.2

# System packages — devcontainer baseline + network/diag tools.
# Removed: qemu-utils, libguestfs-tools, linux-image-generic (no more local
# image building of guest disks — Talos via Image Factory replaces all of it).
RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
    && apt-get install -y --no-install-recommends \
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
        dnsutils \
        iputils-ping \
        iproute2 \
        nmap \
        ipmitool \
    && pip3 install --no-cache-dir yamllint==1.35.1 \
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

# talosctl
RUN curl -fsSL -o /usr/local/bin/talosctl \
    "https://github.com/siderolabs/talos/releases/download/v${TALOS_VERSION}/talosctl-linux-amd64" \
    && chmod +x /usr/local/bin/talosctl

# kustomize
RUN curl -fsSL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize/v${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz" \
    | tar -xz -C /usr/local/bin kustomize

# kubeconform (CI manifest validation)
RUN curl -fsSL "https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}/kubeconform-linux-amd64.tar.gz" \
    | tar -xz -C /usr/local/bin kubeconform

# gitleaks
RUN curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
    | tar -xz -C /usr/local/bin gitleaks

# oras (OCI artifact push for Talos infra images)
RUN curl -fsSL "https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/oras_${ORAS_VERSION}_linux_amd64.tar.gz" \
    | tar -xz -C /usr/local/bin oras

# kyverno CLI (policy tests in CI + locally)
RUN curl -fsSL "https://github.com/kyverno/kyverno/releases/download/v${KYVERNO_VERSION}/kyverno-cli_v${KYVERNO_VERSION}_linux_x86_64.tar.gz" \
    | tar -xz -C /usr/local/bin kyverno

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

# Set zsh as default for vscode user
USER vscode
RUN sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended \
    && echo 'export PATH=$HOME/.local/bin:$PATH' >> ~/.zshrc

USER root

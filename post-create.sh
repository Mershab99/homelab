#!/bin/bash
set -e

echo "=== Homelab Devcontainer Setup ==="

# Shell completions for zsh
mkdir -p ~/.oh-my-zsh/completions

kubectl completion zsh > ~/.oh-my-zsh/completions/_kubectl 2>/dev/null || true
helm completion zsh > ~/.oh-my-zsh/completions/_helm 2>/dev/null || true
flux completion zsh > ~/.oh-my-zsh/completions/_flux 2>/dev/null || true
clusterctl completion zsh > ~/.oh-my-zsh/completions/_clusterctl 2>/dev/null || true
talosctl completion zsh > ~/.oh-my-zsh/completions/_talosctl 2>/dev/null || true
task --completion zsh > ~/.oh-my-zsh/completions/_task 2>/dev/null || true

# Aliases — keep this section idempotent (post-create runs every container start)
if ! grep -q '# homelab-aliases-start' ~/.zshrc 2>/dev/null; then
cat >> ~/.zshrc << 'EOF'

# homelab-aliases-start
# Kubectl
alias k='kubectl'
alias kgp='kubectl get pods'
alias kgs='kubectl get svc'
alias kgn='kubectl get nodes'
alias kga='kubectl get all'
alias kgcp='kubectl get clusterprofiles.config.projectsveltos.io -A'
alias kget='kubectl get eventtriggers.lib.projectsveltos.io -A'
alias kgsc='kubectl get serverclass -A'
alias kgsv='kubectl get server -A'
alias kgtcp='kubectl get tenantcontrolplane -A'
alias kgvm='kubectl get virtualmachine -A'
alias kgvmi='kubectl get virtualmachineinstance -A'

# Talos
alias t='talosctl'
alias tg='talosctl get'
alias td='talosctl dashboard'

# Flux
alias fgk='flux get kustomizations'
alias fgh='flux get helmreleases -A'
alias fgs='flux get sources all'
alias fr='flux reconcile'

# Context
alias kctx='kubectl config get-contexts'
alias kuse='kubectl config use-context'
# homelab-aliases-end
EOF
fi

# SSH permissions if mounted
if [ -d ~/.ssh ]; then
    cp -r ~/.ssh ~/.ssh-local 2>/dev/null || true
    chmod 700 ~/.ssh-local 2>/dev/null || true
    chmod 600 ~/.ssh-local/* 2>/dev/null || true
fi

# Verify tools
echo ""
echo "=== Installed Tools ==="
printf "  %-16s %s\n" "task"        "$(task --version 2>&1 | head -1)"
printf "  %-16s %s\n" "kubectl"     "$(kubectl version --client 2>&1 | head -1)"
printf "  %-16s %s\n" "helm"        "$(helm version --short 2>&1)"
printf "  %-16s %s\n" "flux"        "$(flux --version 2>&1)"
printf "  %-16s %s\n" "clusterctl"  "$(clusterctl version 2>&1 | head -1)"
printf "  %-16s %s\n" "talosctl"    "$(talosctl version --client 2>&1 | head -1)"
printf "  %-16s %s\n" "kustomize"   "$(kustomize version 2>&1 | head -1)"
printf "  %-16s %s\n" "kubeconform" "$(kubeconform -v 2>&1 | head -1)"
printf "  %-16s %s\n" "sops"        "$(sops --version 2>&1 | head -1)"
printf "  %-16s %s\n" "age"         "$(age --version 2>&1)"
printf "  %-16s %s\n" "gitleaks"    "$(gitleaks version 2>&1 | head -1)"
printf "  %-16s %s\n" "oras"        "$(oras version 2>&1 | head -1)"
printf "  %-16s %s\n" "kyverno"     "$(kyverno version 2>&1 | head -1)"
printf "  %-16s %s\n" "k9s"         "$(k9s version --short 2>&1 | head -1 || echo installed)"
printf "  %-16s %s\n" "yq"          "$(yq --version 2>&1)"
printf "  %-16s %s\n" "yamllint"    "$(yamllint --version 2>&1)"
printf "  %-16s %s\n" "ipmitool"    "$(ipmitool -V 2>&1 | head -1)"
printf "  %-16s %s\n" "docker"      "$(docker --version 2>&1)"
echo ""
echo "=== Ready ==="
echo "Run 'task' to list operations."

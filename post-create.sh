#!/bin/bash
set -e

echo "=== Homelab Devcontainer Setup ==="

# Shell completions for zsh
mkdir -p ~/.oh-my-zsh/completions

kubectl completion zsh > ~/.oh-my-zsh/completions/_kubectl 2>/dev/null || true
helm completion zsh > ~/.oh-my-zsh/completions/_helm 2>/dev/null || true
flux completion zsh > ~/.oh-my-zsh/completions/_flux 2>/dev/null || true
clusterctl completion zsh > ~/.oh-my-zsh/completions/_clusterctl 2>/dev/null || true
task --completion zsh > ~/.oh-my-zsh/completions/_task 2>/dev/null || true

# kubectl aliases
cat >> ~/.zshrc << 'EOF'

# Kubectl aliases
alias k='kubectl'
alias kgp='kubectl get pods'
alias kgs='kubectl get svc'
alias kgn='kubectl get nodes'
alias kga='kubectl get all'
alias kgbmh='kubectl get baremetalhost -A'
alias kgtcp='kubectl get tenantcontrolplane -A'
alias kgcp='kubectl get clusterprofile -A'

# Flux aliases
alias fgk='flux get kustomizations'
alias fgh='flux get helmreleases'
alias fgs='flux get sources all'
alias fr='flux reconcile'

# Quick context
alias kctx='kubectl config get-contexts'
alias kuse='kubectl config use-context'
EOF

# Fix SSH permissions if mounted
if [ -d ~/.ssh ]; then
    cp -r ~/.ssh ~/.ssh-local 2>/dev/null || true
    chmod 700 ~/.ssh-local 2>/dev/null || true
    chmod 600 ~/.ssh-local/* 2>/dev/null || true
fi

# Verify tools
echo ""
echo "=== Installed Tools ==="
printf "  %-16s %s\n" "task" "$(task --version 2>&1 | head -1)"
printf "  %-16s %s\n" "kubectl" "$(kubectl version --client --short 2>/dev/null || kubectl version --client 2>&1 | head -1)"
printf "  %-16s %s\n" "helm" "$(helm version --short 2>&1)"
printf "  %-16s %s\n" "flux" "$(flux --version 2>&1)"
printf "  %-16s %s\n" "clusterctl" "$(clusterctl version --short 2>&1 || clusterctl version 2>&1 | head -1)"
printf "  %-16s %s\n" "sveltosctl" "$(sveltosctl version 2>&1 | head -1 || echo 'installed')"
printf "  %-16s %s\n" "sops" "$(sops --version 2>&1)"
printf "  %-16s %s\n" "age" "$(age --version 2>&1)"
printf "  %-16s %s\n" "k9s" "$(k9s version --short 2>&1 | head -1 || echo 'installed')"
printf "  %-16s %s\n" "yq" "$(yq --version 2>&1)"
printf "  %-16s %s\n" "qemu-img" "$(qemu-img --version 2>&1 | head -1)"
printf "  %-16s %s\n" "virt-customize" "$(virt-customize --version 2>&1 || echo 'installed')"
printf "  %-16s %s\n" "ipmitool" "$(ipmitool -V 2>&1 | head -1)"
printf "  %-16s %s\n" "docker" "$(docker --version 2>&1)"
echo ""
echo "=== Ready ==="
echo "Run 'task' to see available build tasks"

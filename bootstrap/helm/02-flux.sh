#!/usr/bin/env bash
# Install Flux (source-controller + helm-controller only) and hand off. Idempotent.
#
# This is the whole delivery bootstrap: install Flux + the git credential, then
# `kubectl apply -f bootstrap/flux/`. source-controller syncs the repo + the
# Sveltos chart; helm-controller installs Sveltos from the HelmRelease. Sveltos
# then drives everything else. No Flux Operator, no FluxInstance, no ArgoCD.
set -euo pipefail

FLUX2_VERSION="${FLUX2_VERSION:-2.14.0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VALUES="${SCRIPT_DIR}/values/flux.yaml"

if ! command -v helm >/dev/null; then
  echo "ERROR: helm not installed" >&2
  exit 1
fi
if [ ! -f "$VALUES" ]; then
  echo "ERROR: $VALUES not found" >&2
  exit 1
fi

echo "==> Adding fluxcd-community chart repo"
helm repo add fluxcd-community https://fluxcd-community.github.io/helm-charts --force-update
helm repo update fluxcd-community

echo "==> Installing flux2 (source + helm controllers) ${FLUX2_VERSION}"
helm upgrade --install flux2 fluxcd-community/flux2 \
  --version "${FLUX2_VERSION}" \
  --namespace flux-system --create-namespace \
  --values "${VALUES}" \
  --wait \
  --timeout 5m

echo "==> Creating git credential (idempotent) — needs FLUX_REPO_PAT env"
if [ -n "${FLUX_REPO_PAT:-}" ]; then
  kubectl -n flux-system create secret generic flux-repo-pat \
    --from-literal=username="${FLUX_REPO_USER:-mershab}" \
    --from-literal=password="${FLUX_REPO_PAT}" \
    --dry-run=client -o yaml | kubectl apply -f -
else
  echo "    FLUX_REPO_PAT not set — assuming flux-repo-pat Secret already exists"
fi

echo "==> Applying bootstrap/flux/ (GitRepository + Sveltos HelmRepository/HelmRelease)"
kubectl apply -f "${REPO_ROOT}/bootstrap/flux/"

echo "==> Verifying"
kubectl -n flux-system wait gitrepository/homelab --for=condition=Ready --timeout=120s \
  && echo "GitRepository homelab Ready"
kubectl -n flux-system wait helmrelease/sveltos --for=condition=Ready --timeout=300s \
  && echo "Sveltos HelmRelease Ready"
kubectl -n projectsveltos get sveltoscluster mgmt 2>/dev/null \
  && echo "mgmt SveltosCluster registered" \
  || echo "    (mgmt not registered yet — give it a moment, then check)"

cat <<'EOF'

============================================================
 Flux is up and Sveltos is installed. Next:
   1. Label the mgmt cluster (see docs/bootstrap.md step 5).
   2. kubectl apply -f clusters/baremetal/sveltos-root.yaml
============================================================
EOF

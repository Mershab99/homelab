#!/usr/bin/env bash
# Bootstrap Cilium on the freshly-Talos'd cluster.
#
# Idempotent: `helm upgrade --install`. Re-run after editing values/cilium.yaml.
#
# Pre-reqs:
#   - helm, kubectl, cilium CLI installed
#   - KUBECONFIG pointed at the bare-metal cluster
set -euo pipefail

CILIUM_VERSION="${CILIUM_VERSION:-1.17.0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES="${SCRIPT_DIR}/values/cilium.yaml"

if ! command -v helm >/dev/null; then
  echo "ERROR: helm not installed" >&2
  exit 1
fi
if ! command -v kubectl >/dev/null; then
  echo "ERROR: kubectl not installed" >&2
  exit 1
fi
if [ -z "${KUBECONFIG:-}" ] && [ ! -f "$HOME/.kube/config" ]; then
  echo "ERROR: KUBECONFIG not set and ~/.kube/config absent" >&2
  exit 1
fi
if [ ! -f "$VALUES" ]; then
  echo "ERROR: $VALUES not found" >&2
  exit 1
fi

echo "==> Adding Cilium chart repo"
helm repo add cilium https://helm.cilium.io --force-update
helm repo update cilium

echo "==> Installing Cilium ${CILIUM_VERSION}"
helm upgrade --install cilium cilium/cilium \
  --version "${CILIUM_VERSION}" \
  --namespace kube-system \
  --values "${VALUES}" \
  --wait \
  --timeout 10m

echo "==> Verifying Cilium status"
if command -v cilium >/dev/null; then
  cilium status --wait
else
  echo "(cilium CLI not installed — skipping cilium status; relying on helm --wait)"
  kubectl -n kube-system get pods -l k8s-app=cilium
fi

cat <<'EOF'

============================================================
 Cilium is up. Next:
   ./bootstrap/helm/02-flux-operator.sh
============================================================
EOF

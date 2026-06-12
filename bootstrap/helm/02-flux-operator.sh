#!/usr/bin/env bash
# Bootstrap the Flux Operator. Idempotent.
#
# Flux Operator owns the FluxInstance CR; the FluxInstance describes which
# Flux controllers to install and how. Apply bootstrap/flux/ after this.
set -euo pipefail

FLUX_OPERATOR_VERSION="${FLUX_OPERATOR_VERSION:-0.21.0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES="${SCRIPT_DIR}/values/flux-operator.yaml"

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

echo "==> Installing flux-operator ${FLUX_OPERATOR_VERSION}"
helm upgrade --install flux-operator fluxcd-community/flux-operator \
  --version "${FLUX_OPERATOR_VERSION}" \
  --namespace flux-system --create-namespace \
  --values "${VALUES}" \
  --wait \
  --timeout 5m

echo "==> Verifying Flux Operator"
kubectl -n flux-system get pods
kubectl get crd fluxinstances.fluxcd.controlplane.io >/dev/null \
  && echo "FluxInstance CRD present"

cat <<'EOF'

============================================================
 Flux Operator is up. Next:
   kubectl apply -f bootstrap/flux/
============================================================
EOF

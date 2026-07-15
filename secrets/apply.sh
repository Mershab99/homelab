#!/usr/bin/env bash
# Apply every filled mgmt cluster secret at once via secrets/kustomization.yaml.
# These are plaintext + gitignored; fill each from its *.example.yaml first
# (see README.md). Run after Flux/Sveltos is up — charts consume them by name.
#
# Re-runnable: if a Secret's namespace doesn't exist yet (its chart hasn't
# created it), that resource errors — re-run once the ClusterProfile has.
#
# Tenant-only secrets (kubevirt-csi infra kubeconfig, tenant cloudflare token)
# are NOT in the kustomization — apply those with KUBECONFIG pointed at arrakis.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
kubectl apply -k "$SCRIPT_DIR"

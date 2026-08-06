# secrets

Cluster secrets are **plaintext manifests applied by hand to mgmt** — no
sealed-secrets, no SOPS, no External Secrets Operator. Only templates live in
git; the filled files are gitignored. Tenant-consumed secrets are applied to mgmt
too (ns `tenant-secrets`) and **propagated to arrakis by Sveltos** (the
`tenant-secrets` ClusterProfile + template ConfigMap) — nothing is applied against
the arrakis context by hand.

## Convention

- `*.example.yaml` — committed template with `REPLACE_WITH_…` placeholders.
- `*.secret.yaml`  — your filled copy. **Gitignored** (`.gitignore: *.secret.yaml`). Never committed.

## Usage

```bash
# 1. Seed *.secret.yaml from every *.example.yaml:
./secrets/init.sh

# 2. Fill in the values (replace REPLACE_WITH_ placeholders):
$EDITOR secrets/infrastructure/dex/dex-config.secret.yaml   # ...and the rest

# 3. Apply them all (kustomize):
kubectl apply -k secrets/     # or: ./secrets/apply.sh (same thing)
```

`secrets/kustomization.yaml` lists the mgmt `*.secret.yaml` files — comment out
any you haven't filled (kustomize errors on a missing file). Run after Flux +
Sveltos are up. Charts consume these Secrets by name; if a namespace doesn't
exist yet, re-run once its ClusterProfile has created it.

**Tenant secrets are propagated, not hand-applied.** The tenant-consumed sources
live in the `tenant-secrets` ns on mgmt (applied by `apply.sh`); the
`tenant-secrets` ClusterProfile copies them to arrakis's real namespaces via
Sveltos `templateResourceRefs`. kubevirt-csi needs NO secret at all (Mode B uses
the CAPI-minted `arrakis-kubeconfig`).

## Inventory

| Secret | mgmt source ns | → arrakis ns | Used by |
|--------|-----------|---------|---------|
| `cloudflare-api-token` | cert-manager | — | cert-manager DNS-01 (mgmt) |
| `cloudflare-api-token` | external-dns | external-dns | external-dns (mgmt + propagated to arrakis) |
| `dex-config` | tenant-secrets | dex | Dex (06-auth-stack, on arrakis) |
| `grafana-oidc` | monitoring | — | Grafana generic_oauth (mgmt) |
| `loki-minio` | monitoring | — | MinIO + Loki S3 (mgmt) |
| `node-01-credentials` | chisel-operator-system | — | mgmt chisel ExitNode (02-ingress-external) |
| `digitalocean-auth` | tenant-secrets | ingress-nginx | chisel DO exit-node provisioner (12-tenant-ingress) |
| `coder-oidc` | tenant-secrets | coder | Coder OIDC (15-app-coder) |

The `dex-config` client secrets must match their consumers' secrets
(`grafana-oidc.clientSecret` == dex `grafana` staticClient secret, etc.).
See each dir's README for how to generate values.

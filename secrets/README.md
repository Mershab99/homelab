# secrets

Cluster secrets are **plaintext manifests applied by hand** — no sealed-secrets,
no SOPS, no External Secrets Operator. Only templates live in git; the filled
files are gitignored.

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

**Tenant secrets** (not in the kustomization — different cluster): apply
`kubevirt-csi/infra-cluster-credentials.secret.yaml` and a second copy of the
cloudflare token (tenant's external-dns ns) with `KUBECONFIG` pointed at arrakis.

## Inventory

| Secret | Namespace | Used by |
|--------|-----------|---------|
| `cloudflare-api-token` | cert-manager | cert-manager DNS-01 (01-edge) |
| `cloudflare-api-token` | external-dns | external-dns (01-edge) — same token, second ns |
| `dex-config` | dex | Dex (06-auth-stack); day-1 user mershab/mershab |
| `grafana-oidc` | monitoring | Grafana generic_oauth (07-observability-backend) |
| `loki-minio` | monitoring | MinIO + Loki S3 (04-storage / 07-observability-backend) |
| `node-NN-credentials` | chisel-operator-system | chisel ExitNodes (02-ingress-external) |

The `dex-config` client secrets must match their consumers' secrets
(`grafana-oidc.clientSecret` == dex `grafana` staticClient secret, etc.).
See each dir's README for how to generate values.

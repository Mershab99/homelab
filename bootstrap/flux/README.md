# Flux (source + helm controllers)

Flux runs only **source-controller** (git + chart fetcher) and
**helm-controller** (reconciles the one Sveltos HelmRelease). No Flux Operator,
no `FluxInstance`, no kustomize/notification/image controllers, no ArgoCD.
Sveltos reads from the `homelab` GitRepository artifact and drives all delivery.

## Layout

```
bootstrap/flux/
├── gitrepository.yaml          # source of truth (github.com/mershab/homelab @ master)
├── sveltos-helmrepository.yaml # Sveltos chart source
├── sveltos-helmrelease.yaml    # the ONE HelmRelease — Flux installs Sveltos
└── README.md
```

The controllers themselves are helm-installed by `bootstrap/helm/02-flux.sh`,
which also creates the git secret and `kubectl apply`s this whole directory.

## Seed secret (created manually, not in Git)

One secret only — the git credential source-controller uses to clone the
private repo. `02-flux.sh` creates it if you export `FLUX_REPO_PAT` (and
optionally `FLUX_REPO_USER`, default `mershab`). By hand:

```bash
kubectl create namespace flux-system
kubectl -n flux-system create secret generic flux-repo-pat \
  --from-literal=username=mershab \
  --from-literal=password=<the-pat>
```

PAT needs `repo:read`. Referenced by name in `gitrepository.yaml`. Rotate by
re-creating the Secret; source-controller re-reads on next reconcile.

> No `sops-age` secret needed — there is no kustomize-controller doing SOPS
> decryption. In-cluster secrets are SealedSecrets, decrypted by the
> sealed-secrets controller (delivered by the `sealed-secrets` ClusterProfile).

## Apply

Handled by `02-flux.sh`. Manually:

```bash
kubectl apply -f bootstrap/flux/
```

helm-controller reconciles the Sveltos HelmRelease → Sveltos installs into
`projectsveltos` and auto-registers the cluster as `mgmt`. `bootstrap/flux/`
itself is NOT reconciled by anything — it changes rarely and self-managing it
would create a dependency cycle.

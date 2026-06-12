# Flux root

The minimum set of manifests Flux Operator needs to take over reconciliation
of the repo.

## Layout

```
bootstrap/flux/
├── fluxinstance.yaml         # FluxInstance CR — Operator installs Flux from this
├── gitrepository.yaml        # source of truth (github.com/mershab/homelab @ master)
├── root-kustomization.yaml   # entry point: clusters/baremetal/
└── README.md
```

## Seed secrets (created manually, not in Git)

Before applying anything in this directory you must create two seed secrets
in `flux-system`. They sit outside the GitOps loop because Flux needs them
to enter the loop in the first place.

### 1. GitHub PAT — for cloning the repo

The PAT needs at minimum `repo:read` on this repo. (No webhook / workflow
scope needed.)

```bash
kubectl create namespace flux-system
kubectl -n flux-system create secret generic flux-repo-pat \
  --from-literal=username=mershab \
  --from-literal=password=<the-pat>
```

### 2. SOPS age key — for decrypting downstream sealed secrets

```bash
# Re-use the age private key you created when populating .sops.yaml.
kubectl -n flux-system create secret generic sops-age \
  --from-file=age.agekey=$HOME/.config/sops/age/keys.txt
```

Both are referenced by name in `gitrepository.yaml` /
`root-kustomization.yaml`. If you ever rotate them, re-create the Secret —
Flux re-reads on the next reconcile.

## Apply order

```bash
kubectl apply -f bootstrap/flux/gitrepository.yaml
kubectl apply -f bootstrap/flux/fluxinstance.yaml
kubectl apply -f bootstrap/flux/root-kustomization.yaml
```

`gitrepository` first so the FluxInstance has its source ready by the time
controllers come up. The root Kustomization reconciles `clusters/baremetal/`
from there.

## After this

Everything in `clusters/baremetal/` is GitOps-managed. `bootstrap/flux/`
itself is intentionally NOT reconciled — these manifests change rarely and
managing them via Flux would create a dependency cycle.

# Helm bootstrap

Two `helm install` calls from your workstation against the freshly-Talos'd
cluster. There is **no Flux Operator and no ArgoCD** — Flux runs only
source-controller + helm-controller; Sveltos drives all delivery.

| Script | Installs | Why in this order |
|---|---|---|
| `01-cilium.sh` | Cilium (CNI + Hubble; FULL-REMOTE, no LB IPAM / L2 announce) | Cluster has `cni.name=none` — no pod schedules until Cilium is up |
| `02-flux.sh` | Flux (source + helm controllers) + the git secret, then `kubectl apply -f bootstrap/flux/` | source-controller syncs the repo + Sveltos chart; helm-controller installs Sveltos from the HelmRelease |

That's the whole delivery bootstrap: install Flux, mount the secret, apply
`bootstrap/flux/`. Sveltos comes up via its HelmRelease and auto-registers the
cluster as `SveltosCluster/mgmt`. Then label `mgmt` and
`kubectl apply -f clusters/baremetal/sveltos-root.yaml` — the root
ClusterProfile pulls `clusters/baremetal/infrastructure/` +
`platform/sveltos/clusterprofiles/` and Sveltos takes over
(see `docs/bootstrap.md`).

## Values

`values/cilium.yaml` and `values/flux.yaml` are the source of truth for the
bootstrap helm installs. NOT applied via GitOps later — bootstrap values only.
FULL-REMOTE: no LB IPAM pools or L2AnnouncementPolicy are delivered (no LAN LB
path). Sveltos install
values live in the HelmRelease at `bootstrap/flux/sveltos-helmrelease.yaml`.

## Idempotent

Both are `helm upgrade --install`. Edit a values file (or bump a pinned
version) and re-run.

## Pre-reqs

- `helm`, `kubectl`, `cilium` (CLI) installed
- `KUBECONFIG` pointed at the freshly-bootstrapped Talos cluster (see
  `docs/bootstrap.md` §2)
- Git credential for the private repo: either export `FLUX_REPO_PAT`
  (+ optional `FLUX_REPO_USER`) before running `02-flux.sh`, or pre-create the
  `flux-repo-pat` Secret in `flux-system` (see `bootstrap/flux/README.md`)

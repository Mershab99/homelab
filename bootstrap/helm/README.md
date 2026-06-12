# Helm bootstrap

Two `helm install` calls that run from your workstation against the
freshly-Talos'd cluster, before Flux exists.

| Script | Installs | Why first |
|---|---|---|
| `01-cilium.sh` | Cilium (CNI + LB IPAM + L2 announcer + Hubble) | Cluster has `cni.name=none` — no pod can schedule until Cilium is up |
| `02-flux-operator.sh` | Flux Operator | Owns `FluxInstance` CR; everything downstream is Flux-managed |

After both run, apply `bootstrap/flux/` and Flux takes over.

## Values

`values/cilium.yaml` and `values/flux-operator.yaml` are the source of truth.
They are NOT applied via GitOps later — these are bootstrap values only. The
post-bootstrap Cilium config (LB IPAM pools, L2AnnouncementPolicy, Hubble
Ingress) lives at `clusters/baremetal/infrastructure/cilium/`.

If you change `values/cilium.yaml`, re-run `01-cilium.sh` — it's `helm
upgrade --install` and is idempotent.

## Versioning

Both scripts pin chart versions. Bump deliberately. After bumping, re-run.

## Pre-reqs

- `helm`, `kubectl`, `cilium` (CLI) installed
- `KUBECONFIG` pointed at the freshly-bootstrapped Talos cluster (see
  `docs/bootstrap.md` §2)

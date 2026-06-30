# Homelab

A single-bare-metal Talos cluster running KubeVirt + CAPI + Kamaji + vCluster.
One Dex federates OIDC across every kube-apiserver and UI.

## Architecture (one paragraph)

A Dell R730 (R820 later) running Talos. Cilium for CNI + LB IPAM + L2 announce
+ kube-proxy replacement. ZFS (OpenEBS ZFS LocalPV) for storage. KubeVirt for VMs. CAPI + CAPK
+ CABPK + kamaji-operator manage a single tenant cluster "home" whose control
plane runs as pods on the bare-metal cluster and whose workers are KubeVirt
VMs (general / gpu-k80 / gpu-p2000 pools). vClusters provide per-workload API
isolation. Flux Operator manages Flux on bare-metal; Sveltos handles all
cross-cluster delivery (no Flux in tenant or vClusters). Full design lives in
[`docs/architecture.md`](docs/architecture.md).

## Bootstrap

Follow [`docs/bootstrap.md`](docs/bootstrap.md) end-to-end. It is the only
source of truth for cold-start procedure.

## Layout

```
bootstrap/           manual, idempotent, one-time-ish (Talos + Helm + Flux init)
clusters/baremetal/  GitOps tree for the bare-metal cluster
tenants/home/        CAPI cluster + Sveltos profiles + vClusters
platform/sveltos/    selector-driven multi-cluster ClusterProfiles
docs/                architecture + bootstrap runbook + per-task runbooks
secrets/             SOPS-encrypted secrets (see .sops.yaml)
.taskfiles/          Taskfile.dev tasks for local automation
```

## Domain + identity

- All UIs and APIs live under `*.mershab.com`.
- Dex at `auth.mershab.com` is the single OIDC issuer.
- One `OAuth2Client` (`kubernetes`) shared by every kube-apiserver.
- One group taxonomy (`oidc:platform-admins`, `oidc:viewers`).

## Hard rules

See [`docs/architecture.md`](docs/architecture.md#hard-rules). Briefly:
no inline secrets, dashboards-as-code, Dex stays on bare-metal, Sveltos =
capability fanout / Flux = per-instance config (never blur), vCluster boundary
is API-only.

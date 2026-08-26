# VIP allocation map — contraxia `lan-pool` (AUTHORITATIVE)

Coordinator-assigned 2026-08-25. `CiliumLoadBalancerIPPool/lan-pool` =
`192.168.2.240 – 192.168.2.250` (11 addresses).

Three parallel tracks each independently reasoned ".240 is taken, so take .241"
and all three claimed **192.168.2.241**. This file is the tie-break. Pin every
LoadBalancer Service with `lbipam.cilium.io/ips: "<addr>"`.

| Addr | Owner | Service | Status |
|---|---|---|---|
| `.240` | tenants | `kmc-arrakis-lb` (k0smotron arrakis CP) | **LIVE — do not touch** |
| `.241` | cell | **Orca remote server** (`19-orca-cell.yaml`) | assigned — Track A keeps it |
| `.242` | gitea | **Gitea forge** (`21-forge.yaml`) | assigned — Track C **must move here** |
| `.243` | workspaces | **devbox CPU workspace SSH** (`20-cpu-workspace.yaml`) | assigned — Track B **must move here** |
| `.244` | kubewall | KubeWall dashboard (`23-kubewall.yaml`) | assigned — Track C |
| `.245` | kagent | kagent UI / A2A | reserved |
| `.246`–`.250` | — | vCluster cells (`25-vcluster-cell-*`), one per cell | free pool |

## Rationale for the ordering

`.241` stays with the **Orca cell** because it is the highest-value service and
the user pairs the Mac against it (`PAIRING_ADDRESS` is baked into the pod env
and into pairing instructions); a stable, memorable first address is worth most
there. Gitea and the devbox move because they are reachable by name/port in
their runbooks and re-pointing them costs nothing.

## Rule for anything new

Claim the **lowest free address** in the table above, add a row in the same
commit, and grep the other worktrees before assuming an address is free:

```sh
grep -rn 'lbipam.cilium.io/ips' platform/
kubectl --context admin@contraxia --request-timeout=60s get svc -A -o wide | grep -i loadbalancer
```

Only `.240` was actually bound in-cluster at assignment time — everything else
here is a paper reservation until its profile reconciles.

# VIP allocation — contraxia `lan-pool` (AUTHORITATIVE)

Coordinator-assigned 2026-08-25. `CiliumLoadBalancerIPPool/lan-pool` =
`192.168.2.240 – 192.168.2.250` (11 addresses).

Three parallel tracks each independently reasoned ".240 is taken, so take .241"
and all three claimed **192.168.2.241**. This file is the tie-break. Pin every
LoadBalancer Service with `lbipam.cilium.io/ips: "<addr>"`.

## ⚠️ THE POOL OVERLAPS THE ROUTER'S DHCP SCOPE

Discovered live 2026-08-25: **`.242` and `.245` are occupied by unrelated LAN
devices** that answer ARP with their own MACs. Cilium happily *assigned* `.242`
to Gitea and the Service showed `EXTERNAL-IP 192.168.2.242`, but the address was
never reachable from the Mac — the squatter won the ARP race:

```
arp -n 192.168.2.240   ->  18:66:da:ed:9b:c4   (r730, correct)
arp -n 192.168.2.241   ->  18:66:da:ed:9b:c4   (r730, correct)
arp -n 192.168.2.242   ->  5c:a6:e6:84:1c:9b   (SOMEONE ELSE)
arp -n 192.168.2.245   ->  e4:54:e8:5e:ae:8d   (SOMEONE ELSE)
```

`docs/runbook-shamu.md` §0.2 already said the pool "**must be outside the
router's DHCP scope**". It is not. Until that is fixed on the router, treat
`.242` and `.245` as burned, and **probe before claiming**:

```sh
ping -c 1 -W 700 192.168.2.<n>     # silence is necessary, not sufficient
arp -n 192.168.2.<n>               # a non-r730 MAC means taken
```

Permanent fix (router-side, not in git): reserve/exclude `.240-.250` from DHCP,
or shrink the pool to a range that is genuinely outside it.

## Assignments

| Addr | Owner | Service | Status |
|---|---|---|---|
| `.240` | tenants | `kmc-arrakis-lb` (k0smotron arrakis CP) | **LIVE — do not touch** |
| `.241` | cell | **Orca remote server** (`19-orca-cell.yaml`) | LIVE, ARP verified |
| `.242` | — | — | **BURNED — foreign LAN device** |
| `.243` | workspaces | **devbox CPU workspace SSH** (`20-cpu-workspace.yaml`) | assigned |
| `.244` | gitea | **Gitea forge** (`21-forge.yaml`) | assigned (moved off `.242`) |
| `.245` | — | — | **BURNED — foreign LAN device** |
| `.246` | kagent | kagent UI / A2A (`24-kagent-router.yaml`, parked) | reserved |
| `.247`–`.250` | — | vCluster cells | free pool |

KubeWall (`23-kubewall.yaml`) is deliberately **ClusterIP, not a VIP** — its API
is unauthenticated and its SA is cluster-admin, so it stays off the LAN.

## Rationale for the ordering

`.241` stays with the **Orca cell** because it is the highest-value service and
the user pairs the Mac against it (`PAIRING_ADDRESS` is baked into the pod env
and into pairing instructions); a stable, memorable first address is worth most
there. Gitea and the devbox move because they are reachable by name/port in
their runbooks and re-pointing them costs nothing.

## Rule for anything new

Claim the **lowest free address** in the table, add a row in the same commit,
ARP-probe it first, and grep the other worktrees before assuming it is free:

```sh
grep -rn 'lbipam.cilium.io/ips' platform/
kubectl --context admin@contraxia --request-timeout=60s get svc -A -o wide | grep -i loadbalancer
```

A Service showing an `EXTERNAL-IP` is **not** proof of reachability — Cilium
assigns from the pool without checking whether the LAN already uses the address.
Always confirm with `arp -n` from off-box.

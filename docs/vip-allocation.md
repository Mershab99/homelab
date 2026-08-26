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

## The hub edge consumes ZERO pool addresses

`27-ingress-hub.yaml` (added 2026-08-25) puts an ingress-nginx LoadBalancer on
contraxia, but it takes **no** address from `lan-pool`. Its Service carries
`spec.loadBalancerClass: chisel.mershab.com/external`, so Cilium LB-IPAM skips
it entirely and chisel-operator claims it instead, pointing it at a DigitalOcean
droplet. Its external IP is a public DO address, not a `192.168.2.x`.

⚠️ **That class split is what protects every row in the table above.**
chisel-operator chart 0.7.1 documents `loadBalancerClass: ""` as *"When empty,
all LoadBalancer services are reconciled, matching the default behavior."* — an
empty value would make the operator claim `.241`, `.243` and `.244` too and
overwrite their `status.loadBalancer.ingress` with the droplet IP, flapping
every LAN VIP at once. Rules:

- The **edge** Service is the only one on contraxia with that class.
- **Never** add `loadBalancerClass` to a Service pinned with
  `lbipam.cilium.io/ips`.
- **Never** blank the `loadBalancerClass` value in `02-ingress-external.yaml`.

Check after any edge change:

```sh
kubectl --context admin@contraxia --request-timeout=60s get svc -A -o wide \
  | grep -i loadbalancer          # .241/.243/.244 must still show their pinned IPs
```

## Public names (not pool addresses, but allocated the same way)

`*.mershab.com` records are published by external-dns off Ingress hostnames — do
not hand-create them in Cloudflare. Claim a name by adding a row here **and** an
Ingress in `platform/sveltos/manifests/hub-edge/ingresses.yaml`.

| Name | Backend | Status |
|---|---|---|
| `git.mershab.com` | `gitea/gitea-http:3000` | published (also on `.244`) |
| `orca.mershab.com` | `cell/orca:6768` | published, **behind nginx basic auth** |
| `kubewall.mershab.com` | — | **RESERVED, must stay unpublished** (unauthenticated API) |
| `kagent.mershab.com` | — | reserved; `24-kagent-router.yaml` is parked |

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

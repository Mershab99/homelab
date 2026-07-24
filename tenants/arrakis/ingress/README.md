# Tenant ingress edge (arrakis)

The app ingress edge runs on the **tenant** (arrakis), not mgmt. This is where
public apps (Jellyfin, website, public-app, Coder UI) attach an HTTPRoute and
get tunnelled out to the internet. Delivered by
`platform/sveltos/clusterprofiles/12-tenant-ingress.yaml`.

## Two VPS, two chisel-operators — why

chisel-operator is per-API-server and binds **1:1 ExitNode↔Service** (hard rule,
learned 2026-07-16: two LB Services + one ExitNode flip-flop, whoever reconciles
last steals the tunnel).

| VPS | ExitNode | chisel-operator | Carries |
|---|---|---|---|
| VPS-01 `72.11.146.116` | `node-01` (`clusters/baremetal/addons/chisel-operator/exit-nodes/`) | **mgmt** (`02-ingress-external`) | arrakis API LB (`kmc-arrakis-lb`, 6443/8132) |
| VPS-02 (provision) | `node-02` (`exit-nodes/node-02.yaml`, this dir) | **tenant** (`12-tenant-ingress`) | Traefik public LB (80/443) |

VPS-02 is the single tenant public edge. As more public Services land — the
public DB TCP path (Phase 4) and Netbird self-hosted signaling (Phase 2) — the
1:1 rule means each needs its own ExitNode entry (add `node-03.yaml` here) or
its own VPS. **Do not** point two LB Services at one ExitNode.

## Gates to close before this edge works end-to-end

1. **Provision VPS-02.** Run `chisel server --auth "chisel:<TOKEN>" --port 9090
   --reverse` with 80/443 bound. Fill `exit-nodes/node-02.yaml spec.host` + apply
   `secrets/infrastructure/chisel-operator/node-02-credentials.secret.yaml`
   **against the tenant** (`./secrets/apply.sh`).
2. **Pin the Traefik chart version** in `12-tenant-ingress.yaml` (repo rule:
   exact pin, wildcards trip sveltos semver). Confirm it installs the standard
   Gateway API CRDs; the experimental CRDs ship from `tenant-gateway/`.
3. **external-dns HTTPRoute source on the tenant.** `01-dns.yaml:42` gates the
   `gateway-httproute` source to mgmt only (it crashloops where Gateway CRDs are
   absent). In the SAME rollout that enables `12-tenant-ingress` (which installs
   the Gateway CRDs), flip that gate to also enable the source on arrakis —
   otherwise tenant HTTPRoute hostnames never publish to Cloudflare.

Already satisfied: cert-manager + `letsencrypt-prod` run on arrakis (`persona=platform`),
and Dex is now a tenant same-cluster backend (`06-auth-stack` → `persona=platform`), so
`auth.mershab.com` is fronted by `tenant-gateway/httproutes.yaml`.

## What's private (NOT on this edge)

Admin UIs (Longhorn, Hubble, Grafana, Traefik dashboard) and all private apps
(Home Assistant, immich, paperless, DB admin) reach via the **Netbird overlay**
(Phase 2), never the public Gateway.

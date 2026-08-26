# TRACK F — contraxia's own public edge (ingress-nginx + chisel→DO + `*.mershab.com`)

**Date:** 2026-08-25 · **Branch:** `contraxia-edge` (Orca worktree; push it to
gitea as `feat/contraxia-edge`) · **Cluster:** contraxia (`admin@contraxia`,
single Talos CP node `r730` @ `192.168.2.70`)

> **Nothing in this report has been applied.** `kubectl apply` / `helm install`
> are deny-listed by design — the write path is git and Sveltos reconciles.
> Every claim below is either backed by a read-only command whose output is
> quoted, or explicitly marked **`UNVERIFIED`**. The end-to-end path (droplet →
> tunnel → nginx → app) **cannot** be proven from here and is `UNVERIFIED` in
> full.

---

## 1. What shipped

| # | File | Change |
|---|---|---|
| 1 | `platform/sveltos/clusterprofiles/27-ingress-hub.yaml` | **NEW** — ingress-nginx 4.15.1 on contraxia, one chisel-classed LB |
| 2 | `platform/sveltos/manifests/hub-edge/digitalocean-provisioner.yaml` | **NEW** — DO `ExitNodeProvisioner`, ns `ingress-nginx` |
| 3 | `platform/sveltos/manifests/hub-edge/ingresses.yaml` | **NEW** — the complete public surface, one file |
| 4 | `platform/sveltos/clusterprofiles/02-ingress-external.yaml` | selector `persona=platform` → `persona In [infra, platform]`; header amended |
| 5 | `platform/sveltos/clusterprofiles/12-tenant-ingress.yaml` | header amended (rule reversal recorded); **no spec change** |
| 6 | `platform/sveltos/clusterprofiles/21-forge.yaml` | stale "no HTTP router on contraxia" claim corrected; `ROOT_URL` cutover staged as commented lines |
| 7 | `platform/sveltos/clusterprofiles/kustomization.yaml` | lists `27-ingress-hub.yaml` |
| 8 | `docs/vip-allocation.md` | edge consumes **zero** pool addresses; `loadBalancerClass` rule; public-name table |

**Profile 28 was not needed and is unclaimed.** Retargeting `02` beat adding a
hub-only twin: same chart, same version, byte-identical values, and two profiles
installing one Helm release name would drift or fight. `01-dns.yaml` already uses
the exact `persona In [infra, platform]` shape, so this is the established idiom.

Validation run:

```
$ kustomize build platform/sveltos/clusterprofiles      -> OK
$ kustomize build clusters/baremetal/infrastructure     -> OK
$ python3 -c "yaml.safe_load_all(...)"  on all 6 touched/new files -> OK
```

---

## 2. Hostname table — as implemented

| Name | Backend | TLS | Auth in front | State |
|---|---|---|---|---|
| `git.mershab.com` | `gitea/gitea-http:3000` | `letsencrypt-prod`, secret `gitea-tls` | Gitea's own (registration disabled, signin required) | Ingress shipped |
| `orca.mershab.com` | `cell/orca:6768` | `letsencrypt-prod`, secret `orca-tls` | **nginx HTTP basic auth**, Secret `orca-basic-auth` (hand-applied) | Ingress shipped, **fails closed** until the Secret exists |
| `kubewall.mershab.com` | — | — | — | **RESERVED, deliberately NOT published** — see §7 |
| `kagent.mershab.com` | — | — | — | reserved; `24-kagent-router.yaml` is parked |

LAN paths are unchanged and remain the fallback: `192.168.2.244:3000` (Gitea),
`192.168.2.241:6768` (Orca), `192.168.2.243` (devbox SSH).

Gitea has `DISABLE_SSH: true`, so `git.mershab.com` is **HTTPS-clone only**.

---

## 3. Proof that every pinned values key exists

This is the section the brief made mandatory — two round-1 defects shipped from
assumed keys.

### 3.1 ingress-nginx 4.15.1

```
$ helm show values ingress-nginx --repo https://kubernetes.github.io/ingress-nginx \
    --version 4.15.1 > ingress-nginx-values.yaml
$ wc -l ingress-nginx-values.yaml
    1276
$ grep -n '^  ingressClassResource\|^  publishService\|^  service:\|^    loadBalancerClass\|^  metrics:'
  127:  ingressClassResource:
  177:  publishService:
  492:  service:
  525:    loadBalancerClass: ""
  907:  metrics:
```

Verbatim excerpts of the four keys that carry real risk:

```yaml
# line 525 — controller.service.loadBalancerClass
    # -- Load balancer class of the external controller service. Used by cloud
    # providers to select a load balancer implementation other than the cloud
    # provider default.
    loadBalancerClass: ""

# lines 907-911 — controller.metrics.enabled  (DEFAULT IS FALSE)
  metrics:
    port: 10254
    portName: metrics
    # if this port is changed, change healthz-port: in extraArgs: accordingly
    enabled: false

# lines 932-944 — controller.metrics.serviceMonitor.{enabled,namespaceSelector}
    serviceMonitor:
      enabled: false
      ...
      namespaceSelector: {}
      ## Default: scrape .Release.Namespace or namespaceOverride only
      ## To scrape all, use the following:
      ## namespaceSelector:
      ##   any: true
```

Render, from **the values block extracted out of the committed profile**, not a
hand-written copy:

```
$ python3 -c "yaml.safe_load(open('27-ingress-hub.yaml'))['spec']['helmCharts'][0]['values']" > vals27.yaml
$ helm template ingress-nginx ingress-nginx --repo https://kubernetes.github.io/ingress-nginx \
    --version 4.15.1 -n ingress-nginx -f vals27.yaml
RENDER OK — 20 objects
```

Rendered objects:
`ServiceAccount/ingress-nginx`, `ConfigMap/ingress-nginx-controller`,
`ClusterRole+Binding/ingress-nginx`, `Role+Binding/ingress-nginx`,
`Service/ingress-nginx-controller-metrics`,
`Service/ingress-nginx-controller-admission`,
`Service/ingress-nginx-controller`, `Deployment/ingress-nginx-controller`,
`IngressClass/nginx`, `ValidatingWebhookConfiguration/ingress-nginx-admission`,
`ServiceMonitor/ingress-nginx-controller`, plus the 6 admission-webhook helper
objects and the 2 `ingress-nginx-admission-{create,patch}` Jobs.

The three things that had to land, landed:

```yaml
# Service/ingress-nginx-controller
spec:
  type: LoadBalancer
  loadBalancerClass: chisel.mershab.com/external      # <- Cilium will skip it
metadata:
  annotations:
    chisel-operator.io/exit-node-provisioner: digitalocean-provisioner

# Deployment/ingress-nginx-controller args
--publish-service=$(POD_NAMESPACE)/ingress-nginx-controller
--controller-class=k8s.io/ingress-nginx
--ingress-class=nginx

# ServiceMonitor/ingress-nginx-controller
spec:
  namespaceSelector: {any: true}
  endpoints: [{port: metrics, interval: 30s}]
```

### 3.2 chisel-operator v0.7.1

⚠️ **The chart is not where the repo's `repositoryURL` points.**
`oci://ghcr.io/fyralabs/chisel-operator:v0.7.1` is a **container image index**,
not a chart — `helm show values` on it dies with
`Error: could not load config with mediatype application/vnd.cncf.helm.config.v1+json`.
The chart is one path segment deeper:

```
$ curl ghcr.io/v2/fyralabs/chisel-operator/chisel-operator/tags/list
{"name":"fyralabs/chisel-operator/chisel-operator","tags":["0.1.0","0.6.0","v0.7.0","v0.7.1"]}

$ helm show values oci://ghcr.io/fyralabs/chisel-operator/chisel-operator --version v0.7.1
Pulled: ghcr.io/fyralabs/chisel-operator/chisel-operator:v0.7.1
Digest: sha256:2b879e6ae1aaae7286e3b2cd52d8dd09d186d04da8fa6d9909de3333c3f0df1c
...
# Optional load balancer class handled by the operator. When empty, all LoadBalancer
# services are reconciled, matching the default behavior.
loadBalancerClass: ""            # <- line 53
createCrds: true
```

`02-ingress-external.yaml`'s `repositoryURL` + `chartName:
chisel-operator/chisel-operator` combination is left **unchanged** — it is
already proven to resolve, because Sveltos installed it successfully on arrakis:

```
$ kubectl ... get clustersummary -n tenants ingress-external-capi-arrakis -o json
"featureSummaries": [{"featureID": "Helm", "status": "Provisioned"}]
"helmReleaseSummaries": [{"releaseName": "chisel-operator",
                          "releaseNamespace": "chisel-operator-system",
                          "status": "Managing"}]
```

Render with the pinned value:

```
$ helm template chisel-operator oci://ghcr.io/fyralabs/chisel-operator/chisel-operator \
    --version v0.7.1 -n chisel-operator-system --set loadBalancerClass=chisel.mershab.com/external
          env:
            - name: LOAD_BALANCER_CLASS
              value: "chisel.mershab.com/external"
```

Objects rendered: `ServiceAccount`, **`CustomResourceDefinition/exitnodeprovisioners.chisel-operator.io`**,
**`CustomResourceDefinition/exitnodes.chisel-operator.io`**, `ClusterRole`,
`ClusterRoleBinding`, `Deployment`.

Note the CRDs render from `templates/crds/`, not `crds/` — the round-1 deadlock
pattern. It is **not** a deadlock here, because this release ships no CR of those
kinds; the `ExitNodeProvisioner` is a separate Sveltos `policyRef`.

### 3.3 The ingress-nginx pattern is already proven in this repo

```
$ kubectl ... get clustersummary -n tenants tenant-ingress-capi-arrakis -o json
"featureSummaries": [{"featureID":"Resources","status":"Provisioning"},
                     {"featureID":"Helm","status":"Provisioned"}]
"helmReleaseSummaries": [{"releaseName":"ingress-nginx",
                          "releaseNamespace":"ingress-nginx","status":"Managing"}]
```

---

## 4. Cluster preconditions — all verified read-only, 2026-08-25

| Precondition | Command | Result |
|---|---|---|
| `letsencrypt-prod` usable | `get clusterissuer` | `letsencrypt-prod True 30d` |
| DNS-01 solver covers the zone | `get clusterissuer letsencrypt-prod -o json` | `dns01.cloudflare`, selector `dnsZones: [mershab.com, *.mershab.com]` |
| CF token where cert-manager looks | `get secret -A \| grep cloudflare` | `cert-manager/cloudflare-api-token` **and** `external-dns/cloudflare-api-token` |
| …and that ns is the right one | `get deploy -n cert-manager cert-manager -o jsonpath=…args` | `--cluster-resource-namespace=$(POD_NAMESPACE)` → `cert-manager` ✅ |
| external-dns will publish | `get deploy -n external-dns external-dns …args` | `--source=ingress --source=service --policy=sync --registry=txt --txt-owner-id=homelab-mgmt --txt-prefix=edns-mgmt- --domain-filter=mershab.com --provider=cloudflare` |
| …without fighting arrakis | same, vs. `01-dns.yaml` templating | contraxia `homelab-mgmt`/`edns-mgmt-`; arrakis `homelab-capi-arrakis`/`edns-capi-arrakis-` — **disjoint** ✅ |
| `tls-stack` dep is satisfiable | `get clustersummary -A` | `tls-stack-sveltos-mgmt` → Resources **Provisioned**, Helm **Provisioned** ✅ |
| DO token in the edge ns | `get secret -n ingress-nginx digitalocean-auth -o jsonpath='{.data}'` | exists, key `DIGITALOCEAN_TOKEN` (20d old) — **manual step already done** |
| ns `ingress-nginx` is clean | `get all -n ingress-nginx` | `No resources found` |
| no IngressClass to collide with | `get ingressclass,ingress -A` | `No resources found` → `default: true` is safe |
| no leftover cluster-scoped nginx RBAC/webhook | `get clusterrole,clusterrolebinding,validatingwebhookconfiguration \| grep ingress-nginx` | none |
| ServiceMonitor CRD present | `get crd \| grep monitoring.coreos.com` | `servicemonitors.monitoring.coreos.com` ✅ (so §5's ServiceMonitor won't ship an unknown kind) |
| node will schedule it | `get nodes -o json` | `r730 taints=None` |
| Gateway API still absent | `get gatewayclass` (per COMMON brief) | none — confirms the ingress-nginx choice |

**Leftovers found in ns `ingress-nginx`** (all harmless, all noted):
`digitalocean-auth`, `service-ingress-nginx-controller-auth`,
`ingress-nginx-admission` (the certgen Job's output Secret, no Helm ownership
labels — the new `ingress-nginx-admission-create` Job regenerates it).

---

## 5. Gateway choice — ingress-nginx, and why Traefik buys nothing here

The user asked whether to swap to Traefik or another observability-forward
gateway. **Verdict: stay on ingress-nginx.** The case for Traefik is its
metrics/tracing/access-log story, and on contraxia all three dead-end before
storage, so the advantage evaluates to zero. Verified in-repo:

1. `platform/sveltos/manifests/observability-core/otel-collector.yaml`:
   `pipelines.metrics.exporters: [debug]` (line 70) and
   `pipelines.traces.exporters: [debug]` (line 78). Scraped metrics and OTLP
   traces are logged at basic verbosity and dropped.
2. Same file, `pipelines.logs.receivers: [otlp]` (line 72) — **no `filelog`
   receiver**, and `grep -rli 'promtail\|alloy'` finds nothing. Container stdout
   is never collected, so Traefik's structured access logs would go exactly
   where nginx's already go: nowhere.
3. `platform/sveltos/manifests/observability-backend/datasources.yaml` has
   exactly one datasource: `type: loki`. Loki stores logs, not metrics. There is
   no Prometheus/Mimir/Thanos/VictoriaMetrics `Deployment` or CR anywhere in the
   repo — the only `grep` hits for those names are three comments describing
   them as future work.
4. The platform argument stands independently: no Gateway API CRDs, Cilium's
   Gateway support is off, and turning it on is a values change to the **live
   CNI of a single-node cluster with no second node to fail over to**.

Also topology, not gateway: **chisel tunnels raw TCP and injects no
`X-Forwarded-For`**, so per-client source IP collapses to the tunnel endpoint for
*any* gateway. Traefik would not recover it. That is why `use-forwarded-headers`
is deliberately **not** set — trusting a client-supplied XFF with no trusted
proxy in front would only make source IPs spoofable, buying a fake number
instead of a missing one.

### The real observability defect, now fixed

Chart 4.15.1 defaults `controller.metrics.enabled` to **false** (line 911
above). As first written, this edge would have shipped **no metrics endpoint at
all** — that is the gap a gateway swap would not have closed. Profile 27 now
sets:

```yaml
metrics:
  enabled: true
  serviceMonitor:
    enabled: true
    namespaceSelector:
      any: true
```

Zero new infrastructure: `otel-collector.yaml` sets
`targetAllocator.prometheusCR.enabled` with `serviceMonitorSelector: {}` (line
26) — an empty selector, so the collector auto-discovers this ServiceMonitor
with no scrape config to write. Cost is one extra ClusterIP Service on `:10254`.

### §Observability follow-up — the gap is wider than "scraped then discarded"

```
$ kubectl ... get opentelemetrycollector -A
No resources found
```

`07-observability-core.yaml` is **commented out** of
`platform/sveltos/clusterprofiles/kustomization.yaml` ("`# minimal:`"), so **no
collector is running on contraxia at all**. The five existing kubevirt
ServiceMonitors are equally unscraped. So the accurate statement is:

- today: the ServiceMonitor exists and **nothing reads it**;
- after `07-observability-core` is uncommented: it is discovered and scraped,
  and then **still discarded**, because `pipelines.metrics.exporters` is
  `[debug]`.

Closing it needs (a) a metrics backend + a `prometheusremotewrite` exporter,
(b) a `filelog` receiver for access logs, and (c) uncommenting the profile at
all. The work lives in:

- `platform/sveltos/clusterprofiles/07-observability-core.yaml` (currently
  commented out of `kustomization.yaml`)
- `platform/sveltos/clusterprofiles/07-observability-backend.yaml` (likewise)
- `platform/sveltos/manifests/observability-core/otel-collector.yaml` (the
  `[debug]` exporters and the missing `filelog` receiver)

**Recommended follow-up track. Explicitly out of scope for Track F — none of
those three files were touched by this diff.**

---

## 6. ⚠️ There is an orphaned DigitalOcean droplet and it is still billing

The single most actionable finding of this track, and it predates it.

```
$ kubectl ... get crd | grep chisel
exitnodes.chisel-operator.io    2026-07-27T00:49:41Z      # exitnodeprovisioners: GONE

$ kubectl ... get exitnodes.chisel-operator.io -A
NAMESPACE       NAME                               AGE
ingress-nginx   service-ingress-nginx-controller   20d

$ kubectl ... get exitnode -n ingress-nginx service-ingress-nginx-controller -o json
created:    2026-08-05T07:44:54Z
finalizers: ['exitnode.chisel-operator.io/finalizer']
spec:       {auth: service-ingress-nginx-controller-auth, port: 9090, default_route: true}
status:     {id: "590102937", ip: "165.227.32.29",
             name: "digitalocean-provisioner-service-ingress-nginx-controller",
             provider: "ingress-nginx/digitalocean-provisioner"}
```

**The droplet is alive.** Probed from the Mac:

```
$ curl -m 8 -o /dev/null -w '%{http_code}' http://165.227.32.29:9090/   -> 404   (chisel server answering)
$ nc -z 165.227.32.29 9090                                             -> OPEN
$ nc -z 165.227.32.29 443                                              -> closed (no tunnel client attached)
```

It has been billing for ~20 days with nothing connected to it. This is separate
from arrakis's own edge droplet — two droplets, one DO account. (The arrakis
droplet's IP was not re-read this session; `UNVERIFIED` here.)

**Why it happened:** the 2026-08-05 "move the edge to arrakis" change uninstalled
chisel-operator from contraxia. The finalizer that destroys the droplet only runs
when the operator is there to run it, so deleting the operator first stranded
both the CR and the droplet.

**Why it does not block this profile:** the orphaned CRD carries

```
meta.helm.sh/release-name:      chisel-operator
meta.helm.sh/release-namespace: chisel-operator-system
```

— identical to what profile `02` installs, so Helm **adopts** it rather than
failing with `invalid ownership metadata`. The missing `exitnodeprovisioners`
CRD is simply recreated.

**Two paths. Pick deliberately.**

- **A — adopt (default, $0 extra, likely just works).** Do nothing. When the
  operator returns, the new nginx Service is `ingress-nginx/ingress-nginx-controller`,
  the operator's naming is `service-<service-name>` → `service-ingress-nginx-controller`
  — an exact match for the existing CR — and its auth Secret
  `service-ingress-nginx-controller-auth` is still in the namespace. Expected
  outcome: the tunnel re-attaches to `165.227.32.29` and 443 opens. `UNVERIFIED`.
- **B — destroy and re-provision clean (recommended).** A 20-day-old droplet with
  an unattended chisel server on a public IP is not a great foundation for the
  estate's public edge, and the region is `nyc3`-ish, not the `tor1` the
  provisioner asks for. Order matters — **the finalizer only runs while the
  operator is alive**:

  ```sh
  # 1. Let profile 02 reconcile FIRST so chisel-operator is Running on contraxia.
  kubectl --context admin@contraxia -n chisel-operator-system get deploy chisel-operator

  # 2. THEN delete the CR — the finalizer destroys droplet 590102937.
  kubectl --context admin@contraxia -n ingress-nginx delete \
    exitnode.chisel-operator.io service-ingress-nginx-controller

  # 3. Confirm the droplet is gone in the DO console before profile 27's LB
  #    Service exists, or the operator will simply re-create an ExitNode.
  ```

  If the operator is *not* running, `delete` hangs on the finalizer. Do **not**
  force-remove the finalizer — that strands the droplet again. Destroy it in the
  DO console first, then remove the CR.

**Teardown, generally.** To stop billing for either edge, delete the `ExitNode`
CR **with the operator running** — its finalizer is what calls the DO destroy
API. Deleting the LB Service, the profile, or the operator does *not* stop the
bill.

---

## 7. §Security — what is now reachable from the public internet

### After this lands, exactly two names resolve to the droplet

| Name | Exposure | Assessment |
|---|---|---|
| `git.mershab.com` | Gitea 1.27.0 UI + HTTPS git | **Acceptable.** `DISABLE_REGISTRATION: true`, `REQUIRE_SIGNIN_VIEW: true`, no chart-created admin (its default password is a published constant, so the chart is told to skip admin bootstrap entirely). Anonymous users see a login page. |
| `orca.mershab.com` | `orca serve` on :6768 | **Highest risk on this edge**, gated. See below. |

Everything else on contraxia stays private, and the mechanism is the
`loadBalancerClass` split, not luck: the LAN VIP Services (`cell/orca` `.241`,
`workspaces` devbox `.243`, `gitea/gitea-http` `.244`) are **classless**, so
chisel-operator ignores them and Cilium LB-IPAM keeps their pinned addresses.
Chart 0.7.1 documents the failure mode itself — `loadBalancerClass: ""` means
*"all LoadBalancer services are reconciled"*, which would have the operator
overwrite `status.loadBalancer.ingress` on all three at once.

**Post-rollout check (do this, it is the regression test for the whole design):**

```sh
kubectl --context admin@contraxia --request-timeout=60s get svc -A -o wide | grep -i loadbalancer
#   cell/orca              192.168.2.241   <- must be unchanged
#   workspaces/devbox-ssh  192.168.2.243   <- must be unchanged
#   gitea/gitea-http       192.168.2.244   <- must be unchanged
#   ingress-nginx/ingress-nginx-controller  <public DO IP>
```

### KubeWall — I agree with the prior, emphatically. Keep it off the internet.

Not a matter of taste, and not merely "unauthenticated":

- Its REST API has **no authentication at all**, and
  `POST /api/v1/app/config/kubeconfigs` hot-loads a kubeconfig with no
  credential and no restart.
- On contraxia the blast radius is not a devbox. It is the CAPI/k0smotron
  control plane of the arrakis tenant, the Sveltos management plane that drives
  **every** cluster in this estate, the `tenant-secrets` namespace, and the
  arrakis kubeconfig Secret.
- `23-kubewall.yaml` already did the right things — `ClusterIP`, and a BYO
  ServiceAccount bound to `view` instead of the chart's cluster-admin binding.
  That is a good posture *because* it is only reachable via `port-forward`,
  which itself requires cluster credentials. Publishing it would delete the
  only authentication in the path.

So: **no Ingress.** `kubewall.mershab.com` is reserved in
`docs/vip-allocation.md` precisely so a later track cannot quietly claim it, and
`hub-edge/ingresses.yaml` names it in a "NOT HERE, deliberately" block. Reach it
with:

```sh
kubectl --context admin@contraxia -n kubewall port-forward svc/kubewall 8443:8443
```

Once Track G's NetBird mesh exists, that is the right home for it — a mesh IP
plus `view` RBAC, still never a public A record. **Do not publish it without
explicit user sign-off**, and if it is ever published, an auth proxy in front is
mandatory, not optional.

### Orca — fails closed on purpose

`orca serve` runs agent terminals with a shell, on a pod holding a 100Gi PVC of
OAuth state, on the cluster that manages every other cluster here. Its own
authentication model over 6768 is **`UNVERIFIED`** — the pod is
`ImagePullBackOff` pending the hand-applied `ghcr-pull` Secret, so it could not
be probed. "Unknown auth" in front of "arbitrary code execution" is not a bet to
take on a public address, so the Ingress carries nginx basic auth:

```yaml
nginx.ingress.kubernetes.io/auth-type: basic
nginx.ingress.kubernetes.io/auth-secret: orca-basic-auth
nginx.ingress.kubernetes.io/auth-realm: "orca cell"
```

`orca-basic-auth` is hand-applied and not in git, so **until it is created nginx
returns 503 for this host** — the safe default. If the Orca client turns out to
be unable to present basic credentials, delete those three annotations *and move
the host behind Track G's mesh*. Do not leave it bare.

### Residual risks, stated plainly

- **Source IPs are gone.** chisel tunnels raw TCP with no `X-Forwarded-For`;
  every request in the nginx access log appears to come from the tunnel
  endpoint. Rate-limiting or IP-allowlisting at this edge is therefore not
  meaningful, and `use-forwarded-headers` is deliberately unset (see §5).
- **The droplet is a real, always-on public host** (§6) with a chisel server on
  :9090. It is a machine to patch, not just a line item.
- **One LB is a single point of failure** for both public names, on a
  single-node cluster with no failover. Accepted: that is what 1:1
  Service↔ExitNode binding costs, and the alternative is more droplets.
- **The admission webhook** (`ValidatingWebhookConfiguration/ingress-nginx-admission`)
  will reject malformed Ingresses cluster-wide once installed. Expected, but it
  is a new cluster-scoped failure mode on contraxia.

---

## 8. Manual steps — placeholders only, never real values

Ordered. Steps 1–2 are already satisfied on contraxia (verified); they are
written down so a rebuild does not lose them.

```sh
# 1. DO API token in the EDGE namespace (chisel v0.7.1 resolves the provisioner,
#    and its auth Secret, only in the Service's own namespace).
#    ALREADY PRESENT on contraxia (20d, key DIGITALOCEAN_TOKEN) — re-create only
#    if rebuilding.
kubectl --context admin@contraxia -n ingress-nginx create secret generic \
  digitalocean-auth --from-literal=DIGITALOCEAN_TOKEN='<DO_PERSONAL_ACCESS_TOKEN>'

# 2. Cloudflare token for DNS-01. ALREADY PRESENT in ns cert-manager (that is
#    cert-manager's --cluster-resource-namespace here) AND ns external-dns.
kubectl --context admin@contraxia -n cert-manager create secret generic \
  cloudflare-api-token --from-literal=api-token='<CLOUDFLARE_API_TOKEN>'

# 3. Basic-auth credential for orca.mershab.com. NOT yet present — until this
#    exists, that host 503s (intended).
htpasswd -nbB '<ORCA_USER>' '<ORCA_PASSWORD>' > /tmp/auth
kubectl --context admin@contraxia -n cell create secret generic \
  orca-basic-auth --from-file=auth=/tmp/auth
shred -u /tmp/auth        # or: rm -P /tmp/auth   on macOS

# 4. Decide the orphaned-droplet question — §6, path A or path B.
```

Never commit any of these values. `secrets/` in this repo is plaintext and
gitignored; nothing above was read from it.

### Sanity checks after Sveltos reconciles

```sh
C="kubectl --context admin@contraxia --request-timeout=60s"

# chisel-operator came up on the hub (profile 02's widened selector)
$C get deploy -n chisel-operator-system chisel-operator
$C get crd | grep chisel                     # both CRDs now, not just exitnodes

# the edge itself
$C get pods,svc -n ingress-nginx
$C get svc -n ingress-nginx ingress-nginx-controller -o wide   # EXTERNAL-IP = public DO IP
$C get exitnode -A                                             # one, bound to that Service

# the LAN VIPs did NOT flap  <-- the regression test for the class split
$C get svc -A -o wide | grep -i loadbalancer

# certs (these should go Ready even with the droplet down — DNS-01)
$C get certificate -n gitea gitea-tls
$C get certificate -n cell  orca-tls
$C get certificaterequest,order,challenge -A

# records (from the Mac, NOT from inside the cluster)
dig +short git.mershab.com  @1.1.1.1
dig +short orca.mershab.com @1.1.1.1
dig +short TXT edns-mgmt-git.mershab.com @1.1.1.1   # external-dns ownership record
$C logs -n external-dns deploy/external-dns --tail=50 | grep -i mershab

# end to end
curl -sS -o /dev/null -w '%{http_code} %{ssl_verify_result}\n' https://git.mershab.com/
curl -sS -o /dev/null -w '%{http_code}\n' https://orca.mershab.com/     # expect 401 (or 503 pre-Secret)
```

---

## 9. §Cutover — Gitea `ROOT_URL`, and Orca `PAIRING_ADDRESS`

Both are staged, neither is applied, and the ordering is the point.

**Gitea.** `21-forge.yaml` still sets `DOMAIN: 192.168.2.244` /
`ROOT_URL: http://192.168.2.244:3000/`. Flipping those *before* the droplet is
proven would break the working LAN forge — and this forge is the git remote for
the whole estate, so that is a self-inflicted outage on the write path. The new
values sit as commented lines directly above the live ones. Once
`https://git.mershab.com/` answers:

```yaml
            server:
              DOMAIN: git.mershab.com
              ROOT_URL: https://git.mershab.com/
```

Until then, the UI reached at `git.mershab.com` renders clone URLs pointing at
`192.168.2.244` — cosmetically wrong, functionally harmless, and reversible.

**Orca.** `manifests/orca-cell/orca.yaml` sets
`PAIRING_ADDRESS: "192.168.2.241"`. Remote pairing from off-LAN needs
`orca.mershab.com`. Same ordering rule, and it is a StatefulSet env change (pod
restart). Left alone here — the pod is `ImagePullBackOff` anyway, so flipping it
now would only make a broken thing broken differently.

---

## 10. Cost

| Item | Cost |
|---|---|
| contraxia edge droplet, `s-1vcpu-1gb` `tor1` | **~$6/mo** |
| arrakis edge droplet (pre-existing, `UNVERIFIED` this session) | ~$6/mo |
| **orphaned droplet `590102937` / `165.227.32.29`** (§6) | **~$6/mo, currently wasted** |

So the honest delta of this track is **$0–6/mo**: $0 if the orphan is adopted
(path A), ~$6/mo if it is destroyed and a fresh droplet provisioned (path B).
Either way, path B first *saves* the ~$4 already burned since 2026-08-05 from
recurring.

**Teardown** — the finalizer is what stops the billing:

```sh
# Operator MUST be running. Then:
kubectl --context admin@contraxia -n ingress-nginx delete \
  exitnode.chisel-operator.io service-ingress-nginx-controller
# Verify in the DO console. Deleting the Service, the ClusterProfile, or the
# operator does NOT destroy the droplet.
```

To retire the whole hub edge: remove `27-ingress-hub.yaml` from
`kustomization.yaml`, narrow `02-ingress-external.yaml` back to
`persona: platform`, and delete the ExitNode as above — **in that order**, or
the finalizer is stranded again exactly as it was on 2026-08-05.

---

## 11. What is `UNVERIFIED`

Nothing here was applied, so *everything* is unapplied by construction. These are
the claims that could not even be statically proven:

- **The entire end-to-end path.** droplet → chisel tunnel → nginx → backend.
  Untestable from here.
- **Whether the orphaned ExitNode is adopted or re-provisioned** when the
  operator returns (§6 path A). The name and auth Secret match exactly, so
  adoption is the strong expectation — it is not proof.
- **That Let's Encrypt issues.** The issuer is `Ready` and the solver selector
  covers the zone, but **no `letsencrypt-prod` certificate has ever been issued
  on contraxia** (`get certificate -A` shows only internal `selfsigned-ca` /
  webhook certs). These two will be the first. A `letsencrypt-staging` issuer
  does **not** exist in this repo; for two hostnames against a 50/week limit,
  adding one is not worth it — but if issuance fails, add staging before
  retrying rather than burning duplicate-cert quota (5/week).
- **`orca serve`'s own auth model, and whether it speaks HTTP/WS on 6768 at
  all.** The pod is `ImagePullBackOff`. If it is not an HTTP server, the Ingress
  is inert (503) — which is also safe.
- **Whether the Orca client can present HTTP basic credentials.** If not, §7's
  fallback applies.
- **DO region.** `tor1` is copied from `arrakis-edge`; `165.227.32.29` is not a
  `tor1` prefix, so path A adopts a droplet in a different region than the
  provisioner requests. Harmless, but it means the provisioner spec and reality
  disagree under path A.
- **Sveltos' first-reconcile ordering** between profile 02's CRDs and profile
  27's `ExitNodeProvisioner`. Helm and Resources are independent features
  applied in parallel; a transient `no matches for kind "ExitNodeProvisioner"`
  is expected and self-heals, same class as `23-kubewall`'s ServiceAccount race.
  Do not "fix" it by inlining the CR into a values block.

---

## 12. Branch note

The Orca worktree was created on branch **`contraxia-edge`**; the brief names
`feat/contraxia-edge`. Renaming a live Orca-managed worktree branch risks
wedging Orca's own state, so the local branch keeps its name and it is published
under the briefed name:

```sh
git push gitea contraxia-edge:feat/contraxia-edge
```

`git push origin` is denied by design — the coordinator reviews and pushes.

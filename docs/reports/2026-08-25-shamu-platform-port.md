# TRACK C — Porting the shamu platform onto contraxia

**Date:** 2026-08-25
**Branch:** `feat/shamu-platform-contraxia`
**Source design:** `devex/apps/shamu/`, `devex/docs/runbook-shamu.md`, `devex/docs/decisions.md` #8–#14
**Target:** contraxia — single-node Talos `r730` @ `192.168.2.70`, SveltosCluster `mgmt/mgmt`, label `persona=infra`

Every claim below is followed by the command that produced it. Anything I could
not run is marked **UNVERIFIED** and says why.

---

## 0. The one thing to read if you read nothing else

The shamu design is a **Flux-direct, CAPVC-based, Gateway-API-fronted** design for a
cluster that deliberately ran no management plane. contraxia is the opposite of
all three. Three of its load-bearing assumptions are false here:

1. **There is no ingress path of any kind on contraxia.** No GatewayClass, and
   the `ingress-nginx` and `traefik` namespaces — which the coordinator's brief
   listed as available — are **empty shells**. Everything I landed is therefore
   a LoadBalancer VIP or a `port-forward`, never an Ingress or an HTTPRoute.
2. **CAPVC is dead here.** contraxia runs CAPI core **v1.13.3**; CAPVC v0.2.2 caps
   at v1.10.x. Meeting decision #12's pin means downgrading the core provider
   under a live k0smotron/CAPK provider set that runs the arrakis tenant.
   The vCluster factory is re-based on the Loft OSS Helm chart this repo already
   uses.
3. **KubeWall as designed does not pass on this cluster** — unauthenticated API +
   `cluster-admin` on the box that holds the arrakis kubeconfig and the Sveltos
   management plane. I changed it rather than accepting it. §5.

Gitea — the highest-value item, and the one the brief said to land if only one
lands — **is landed**, wired to a real Postgres instead of the frozen-image
bundled one.

---

## 1. The reconciliation table, corrected and evidence-backed

Verdicts marked ⚠️ **differ from the brief's expectation**.

| shamu component | contraxia reality (verified) | verdict | landed as |
|---|---|---|---|
| `cilium` | Cilium is the live CNI. `CiliumLoadBalancerIPPool/lan-pool` = `192.168.2.240–.250` | **DROP** | — |
| `cilium-pools` | `lan-pool` already exists and covers the range | **DROP** | — |
| `cert-manager` | Running **v1.15.5** in ns `cert-manager`, delivered by the existing `tls-stack` ClusterProfile (selector `persona In [infra, platform]`) | **DROP** ⚠️ *shamu wanted v1.17.0 — do not bump as part of this track* | — |
| `openebs` | Longhorn→ZFS migration owns it; in flight at report time | **DROP** | — |
| `capi` / `capi-providers` | core **v1.13.3**, CAPK **v0.11.2**, k0smotron bootstrap+CP **v2.0.3**, all Ready | **RECONCILE → CAPVC REJECTED** ⚠️ | §4 |
| `gateway` / `gateway-api-crds` | No GatewayClass. **`ingress-nginx` and `traefik` namespaces are EMPTY** | **DROP + REDESIGN** ⚠️ *brief implied these were usable; they are not* | LB VIP / port-forward |
| `netbird-router` | ns `netbird` exists but is **EMPTY**. This repo removed `08-netbird.yaml` on 2026-08-05 ("Netbird ripped") | **DROP** ⚠️ *contradicts the shamu design outright* | — |
| `chisel` | ns `chisel-operator-system` exists but is **EMPTY**. Chisel in this repo (`02-ingress-external`) targets the **arrakis** edge | **DROP** ⚠️ | — |
| `gitea` | Not on contraxia | **PORT** ✅ | `21-forge.yaml` |
| `mcp` | Not on contraxia | **PORT** ✅ | `22-mcp-levers.yaml` |
| `kubewall` | Not on contraxia | **PORT, HARDENED** ✅ | `23-kubewall.yaml` |
| `kubewall-capi-sync` | Exists only to sync CAPVC cell kubeconfig Secrets | **DROP** ⚠️ *no CAPVC ⇒ nothing to sync* | — |
| `kagent` | Not on contraxia | **PORT, PARKED** ⚠️ *Track D ownership unresolved* | `24-kagent-router.yaml` (not in kustomization) |
| `vclusters` | Repo already ships Loft-OSS vcluster profiles (`12-vcluster-*`) | **RECONCILE → re-based off CAPI** | `25-vcluster-cell-TEMPLATE.yaml` |
| *(new)* Postgres | **No Postgres operator on contraxia** — `db-operators` targets `persona=platform` | **ADDED** ✅ | `26-infra-db.yaml` |

### Evidence

```
$ kubectl --context=admin@contraxia --request-timeout=60s get nodes -o wide
NAME   STATUS   ROLES           AGE   VERSION    INTERNAL-IP    OS-IMAGE          CONTAINER-RUNTIME
r730   Ready    control-plane   52d   v1.36.2    192.168.2.70   Talos (v1.13.5)   containerd://2.2.5

$ kubectl ... get sveltoscluster -A --show-labels
NAMESPACE   NAME   READY   VERSION   LABELS
mgmt        mgmt   true    v1.36.2   ...,persona=infra,sveltos.projectsveltos.io/type=mgmt,tier=platform
        # ⇒ contraxia's selector is persona=infra. Every profile I wrote uses it.

$ kubectl ... get gatewayclass
No resources found

$ kubectl ... get all -n ingress-nginx
No resources found in ingress-nginx namespace.
$ kubectl ... get all -n traefik
No resources found in traefik namespace.
$ kubectl ... get all -n netbird
No resources found in netbird namespace.
$ kubectl ... get all -n chisel-operator-system
No resources found in chisel-operator-system namespace.
        # ⇒ four namespaces the brief listed as "exists" are empty shells.

$ kubectl ... get coreprovider,infrastructureprovider,bootstrapprovider,controlplaneprovider -A
capi-system                                 coreprovider/cluster-api            v1.13.3   True
kubevirt-infrastructure-system              infrastructureprovider/kubevirt     v0.11.2   True
k0sproject-k0smotron-bootstrap-system       bootstrapprovider/k0sproject-k0smotron    v2.0.3   True
k0sproject-k0smotron-control-plane-system   controlplaneprovider/k0sproject-k0smotron v2.0.3   True

$ kubectl ... get crd | grep -iE 'cnpg|postgres|moco|mysql'
        (no output)

$ kubectl ... get svc -A | grep -i loadbalancer
tenants   kmc-arrakis-lb   LoadBalancer   10.96.12.118   192.168.2.240   6443:31916/TCP,8132:32095/TCP

$ kubectl ... get deploy -n cert-manager -o jsonpath=...
cert-manager             quay.io/jetstack/cert-manager-controller:v1.15.5
cert-manager-cainjector  quay.io/jetstack/cert-manager-cainjector:v1.15.5
cert-manager-webhook     quay.io/jetstack/cert-manager-webhook:v1.15.5
```

---

## 2. What I landed, in dependency order

The brief's suggested order was
`(cilium/cert-manager) → gitea → mcp → kubewall → capi → vclusters → kagent`.
Actual order, with the one insertion the reconciliation forced:

| # | Profile | Depends on | Status |
|---|---|---|---|
| 20 | `infra-db` — CloudNativePG 0.29.0 (operator 1.30.0) | *(none)* | **LANDED**, in kustomization |
| 21 | `forge` — Gitea chart 12.7.0 (Gitea 1.27.0) | `infra-db` | **LANDED**, in kustomization |
| 22 | `mcp-levers` — flux-operator-mcp 0.58.1 + kubernetes-mcp-server 0.1.0 | *(none)* | **LANDED**, in kustomization |
| 23 | `kubewall` — kubewall 0.0.22, hardened | *(none, deliberately)* | **LANDED**, in kustomization |
| 24 | `kagent-router` — kagent + kagent-crds 0.9.12 | *(none)* | **WRITTEN, PARKED** — not in kustomization |
| 25 | `vcluster-cell-TEMPLATE` — vcluster 0.36.1 | *(none)* | **TEMPLATE** — never listed, copy to spawn |

New payload dirs: `platform/sveltos/manifests/forge/` (ns + CNPG `Cluster/gitea-pg`)
and `platform/sveltos/manifests/kubewall/` (ns + BYO SA + `view` binding).

**Deferred / not done, explicitly:**

- **The forge cutover.** Out of scope by instruction; §8 writes it up.
- **`capi-providers` port.** Rejected, not deferred — see §4.
- **Sveltos auto-registration of contraxia-hosted vclusters.** The existing
  `vcluster-autoregister` EventTrigger is written for arrakis-hosted vclusters.
  Follow-up.
- **Narrowing flux-operator-mcp's cluster-admin.** Deliberately left; §5.

---

## 3. Every pin carried over, and whether I re-verified it

All chart pins re-resolved against live registries on 2026-08-25 with
`helm show chart`. **Every one resolved; two revealed facts the source decisions
got wrong or omitted.**

| Chart | Pin | Source | Re-verified | Notes |
|---|---|---|---|---|
| gitea | **12.7.0** | #8 | ✅ `appVersion: 1.27.0` | Confirms #8's correction of the vault (which said 1.26.4) |
| cloudnative-pg | **0.29.0** | this repo's `09-db-operators` | ✅ `appVersion: 1.30.0` | Reused, not invented |
| kubewall | **0.0.22** | #10/#12 | ✅ `appVersion: 0.0.22` | |
| flux-operator-mcp | **0.58.1** | #13 | ✅ `appVersion: v0.58.1` | |
| kubernetes-mcp-server | **0.1.0** | #13 | ✅ `appVersion: 0.0.66` | Matches #13's app pin exactly |
| kagent / kagent-crds | **0.9.12** | #14 | ✅ both resolve | Lockstep pair |
| vcluster (Loft) | **0.36.1** | this repo's `12-vcluster-*` | ✅ (already live in-repo) | **NOT** #12's 0.22.1 — that pin exists only to match CAPVC, which is dead here |
| kmcp | 0.3.0 | #14 | ✅ `appVersion: 0.3.0` | Not installed by this track; `16-mcp-baseline` already owns it |

### Two pins/claims that did NOT survive contact

- **CAPI core `v1.10.10` (#12's "load-bearing pin") — REJECTED.** §4.
- **cert-manager v1.17.0 (#12) vs contraxia's live v1.15.5.** Not bumped. Nothing
  I landed needs 1.17 (CNPG issues its own certs; the CAPI operator is already
  running against 1.15.5). Bumping the cert plumbing of a live single-node
  management cluster is a separate, riskier change than a shamu port.

### Corrections to the source decisions, found by rendering the charts

1. **Gitea chart 12.7.0 default DB is the reverse of what the value names imply.**
   `postgresql-ha.enabled: true` and `postgresql.enabled: false` are the chart
   defaults. Decision #8's "bundled single Postgres, not postgresql-ha" therefore
   requires setting **both** explicitly. I set both to `false`.
2. **kagent 0.9.12's always-rendered ModelConfig defaults to paid OpenAI.**
   Rendered: `provider: OpenAI`, `model: gpt-4.1-mini`,
   `apiKeySecret: kagent-openai`, key `OPENAI_API_KEY`. That is a Secret which
   does not exist on contraxia, and it contradicts decision #14's
   "no paid-API billing in-cluster". Recorded as a blocking FILL on that profile.

---

## 4. Why the vCluster factory is not a CAPI factory here

Decision #12's central pin: *"CAPVC v0.2.2 declares the CAPI v1beta1 contract …
so CoreProvider is pinned v1.10.10, NOT latest — core v1.11+ goes v1beta2-primary."*

contraxia runs **core v1.13.3** — three minors past that ceiling. Honouring the
pin means **downgrading the core provider on the live management cluster**, whose
other three providers (CAPK v0.11.2, k0smotron bootstrap + control-plane v2.0.3)
are a coherent v1beta2-contract set that runs the arrakis tenant's control plane.
This repo's own `05-capi-stack` header already forbids exactly that:
*"Don't bump one without checking the others' contract — mixing v1beta1/v1beta2
contract providers is what previously held tenant k8s back."*

**Verdict: CAPVC is rejected on contraxia, not deferred.** Revisit only if CAPVC
ships a stable v0.3.x on the v1beta2 contract.

The replacement was already in this repo before the port arrived:
`12-vcluster-family.yaml` / `12-vcluster-mershab.yaml` deploy Loft vcluster OSS as
a plain Helm chart with no CAPI coupling at all. `25-vcluster-cell-TEMPLATE.yaml`
is those profiles re-pointed at `persona=infra`, minus arrakis-specific plumbing
(no Dex OIDC — Dex lives on arrakis; no ingress — contraxia has none;
`fast-zfs` instead of `openebs-zfs`).

Consequence: **`kubewall-capi-sync` is dropped.** Its entire job was polling
`cells/*-kubeconfig` Secrets that CAPVC would have created. Nothing creates them.
Loft vcluster writes `vc-<name>` Secrets instead, and adding them to KubeWall is
a UI action, not a CronJob worth maintaining.

---

## 5. Risk re-evaluation — the section the brief asked for

### 5.1 KubeWall: unauthenticated `cluster-admin` — **DOES NOT PASS. Changed.**

Decision #12 accepted, in writing and twice, that KubeWall's API/UI has **no
authentication** and its SA is bound to **`cluster-admin`**, then put it on a LAN
VIP, justified as "the LAN is the perimeter; same trust boundary as Gitea".

On a devbox that argument holds. On contraxia it does not, and the difference is
not stylistic. `cluster-admin` here means the CAPI/k0smotron control plane of the
arrakis tenant, the **Sveltos management plane that drives every cluster in this
homelab**, the `tenant-secrets` namespace, and the arrakis kubeconfig Secret.
Combined with an endpoint that takes `POST /api/v1/app/config/kubeconfigs` with
no credential, anyone who can reach `192.168.2.0/24` owns the fleet, with no
audit trail.

**Two changes, both free, both verified against chart 0.0.22:**

1. **No LoadBalancer, no VIP.** `service.type: ClusterIP`. Access is
   `kubectl -n kubewall port-forward svc/kubewall 8443:8443`, which already
   requires cluster credentials — restoring the authentication the app lacks.
   Bonus: the chart renders no Service annotations (decision #12 needed a Flux
   `postRenderer` to pin its VIP, and **Sveltos has no postRenderer equivalent**),
   so this removes a problem that had no clean Sveltos answer.
2. **No `cluster-admin`.** `serviceAccount.create: false` + a hand-made SA bound
   to the stock `view` ClusterRole (`manifests/kubewall/rbac.yaml`).

The escape decisions #10/#12 hypothesised ("only escape is BYO-SA") **works, and
is now proven**:

```
$ helm template kw oci://ghcr.io/kubewall/charts/kubewall --version 0.0.22 \
    --set serviceAccount.create=false --set serviceAccount.name=kubewall-ro
      → serviceAccountName: kubewall-ro,  and NO ClusterRoleBinding rendered

# rendered with this repo's actual values:
$ helm template kubewall oci://ghcr.io/kubewall/charts/kubewall --version 0.0.22 \
    -n kubewall -f <values from 23-kubewall.yaml> | grep '^kind:' | sort | uniq -c
   1 kind: Deployment
   1 kind: PersistentVolumeClaim
   1 kind: Secret
   1 kind: Service          # type: ClusterIP, serviceAccountName: kubewall
      → the cluster-admin ClusterRoleBinding is GONE.
```

**Residual risk, stated:** the API is still unauthenticated, so anything that can
reach its ClusterIP *inside* the cluster can drive it — but it can now only
**read**, and only what `view` allows. `view` excludes Secrets by design, so the
dashboard's Secrets tab will 403 against the local cluster. On this cluster that
is a feature.

### 5.2 flux-operator-mcp: cluster-admin, kept — with an honest caveat

`rbac.create: true` grants **`cluster-admin`** (verified in the rendered
ClusterRoleBinding: `roleRef.name: cluster-admin`). I kept it: the tool's job is
reconcile/suspend/resume over arbitrary Flux CRs, and hand-narrowing the role
breaks tools silently and unpredictably.

**I initially wrote in the profile that its NetworkPolicy "fails closed". That was
wrong, and rendering it caught me.** The chart adds its own release namespace
unconditionally:

```
ingress: [{from: [{namespaceSelector: {kubernetes.io/metadata.name: mcp}},
                  {namespaceSelector: {kubernetes.io/metadata.name: cell}}],
           ports: [{port: 9090, protocol: TCP}]}]
```

So it is reachable from the `mcp` namespace today (only `kubernetes-mcp-server`
lives there, and it does not call it) and from `cell`, which does not yet exist.
The comment in `22-mcp-levers.yaml` is corrected to say this.

**→ ACTION FOR WHOEVER LANDS THE ORCA CELL:** the moment namespace `cell` exists,
every agent in it holds cluster-admin over the hub. Re-evaluate
`rbac.create: false` + a ClusterRole scoped to `source.toolkit.fluxcd.io` /
`helm.toolkit.fluxcd.io` at that point. This is the single largest piece of
deferred risk in this track.

The read-only server is genuinely read-only — verified in the render:
`--read-only` arg present, image `quay.io/containers/kubernetes_mcp_server:0.0.66`,
and its only binding is `kubernetes-mcp-server-use-view-role` → stock `view`
(no Secrets).

### 5.3 kagent `auth.mode: unsecure`

Carried over from decision #14, survivable **only** because the Service is
ClusterIP with no route in. Do not give kagent a LoadBalancer VIP without first
turning auth on. The profile is parked anyway.

### 5.4 Plaintext secrets posture (decision #2) now that this is not a laptop

The repo's settled posture (`feedback_sops_only_secrets`, 2026-07-13) is that
cluster secrets are **plaintext + gitignored** (`*.secret.yaml`), applied by hand
via `./secrets/apply.sh`. That is unchanged by this track and I did not touch it.
Two observations that the shamu port makes newly relevant:

1. **This track adds no new plaintext secret, and removes one credential class.**
   Gitea's Postgres password is generated by CNPG into `gitea-pg-app` and consumed
   via `secretKeyRef` — it never exists in git in any form. That is strictly
   better than the bundled chart's published `gitea`/`gitea`.
2. ⚠️ **Unrelated finding, reported because it is a live credential exposure:**
   this worktree's `gitea` git remote URL embeds a Gitea **personal access token
   in plaintext** (visible in `git remote -v`, and therefore in
   `.git/config` and in any shell history or transcript that ran it). I did not
   print, copy or transmit the value. Recommend moving it to a credential helper
   or `~/.git-credentials` and rotating the token. Not in scope to fix here —
   changing the remote would affect the push path this track depends on.
3. Decision #8's *"landing the deployment does not commit to \[making this repo's
   remote a Gitea repo]"* still holds, but the cutover in §8 **is** that commitment,
   and it re-raises the rotate-on-exposure rule for everything under `secrets/`.

---

## 6. LAN-pool IP claims

`CiliumLoadBalancerIPPool/lan-pool` = **192.168.2.240 – 192.168.2.250** (11 addresses).

| Address | Claimed by | Status |
|---|---|---|
| `.240` | `tenants/kmc-arrakis-lb` | **In use** (verified live) |
| **`.241`** | **TRACK C — Gitea `gitea-http` Service** | **CLAIMED by this track** |
| `.242`–`.250` | unclaimed by Track C | free as far as this track is concerned |

**Track C claims exactly one address.** Everything else it landed is ClusterIP +
`port-forward` — KubeWall, both MCP servers, and (if ever enabled) kagent. That is
partly a security decision (§5.1) and partly deliberate courtesy: Tracks A and B
draw from the same 11 addresses.

⚠️ **UNVERIFIED: whether Tracks A or B also claim `.241`.** I asked the
coordinator via `orca orchestration ask` and the 10-minute call timed out with no
answer. If another track has taken `.241`, moving is a one-line change in
`21-forge.yaml` — but **`gitea.config.server.DOMAIN` and `ROOT_URL` must move with
it**, or Gitea will serve clone URLs pointing at the wrong host.

---

## 7. Validation actually performed

```
$ kustomize build platform/sveltos/clusterprofiles > /tmp/cp-built.yaml
exit=0    → 26 ClusterProfiles render (22 pre-existing + 4 new)

# Schema-validated against the LIVE CRD pulled from contraxia:
$ kubectl ... get crd clusterprofiles.config.projectsveltos.io -o json
$ python -m jsonschema (v1beta1 openAPIV3Schema) against each profile
  PASS  ClusterProfile/forge          (kustomize-built)
  PASS  ClusterProfile/infra-db       (kustomize-built)
  PASS  ClusterProfile/kubewall       (kustomize-built)
  PASS  ClusterProfile/mcp-levers     (kustomize-built)
  PASS  ClusterProfile/kagent-router  (unlisted: 24-kagent-router.yaml)
  PASS  ClusterProfile/vcluster-CHANGEME (unlisted: 25-vcluster-cell-TEMPLATE.yaml)
  => ALL PASS

# Every chart templated with the EXACT values from the profiles:
  OK   gitea                  (8 objects)
  OK   cloudnative-pg         (22 objects)
  OK   kubewall               (4 objects)
  OK   flux-operator-mcp      (5 objects)
  OK   kubernetes-mcp-server  (5 objects)
  OK   kagent-crds            (8 objects)
  OK   kagent                 (19 objects)

# Gitea's rendered config confirms the CNPG wiring and the VIP:
  Service gitea-http: type LoadBalancer, annotation lbipam.cilium.io/ips: 192.168.2.244, port 3000
  Secret gitea-inline-config [database]: DB_TYPE=postgres  HOST=gitea-pg-rw.gitea.svc:5432
                                         NAME=gitea  USER=gitea  SSL_MODE=require
  Deployment env: GITEA__database__PASSWD ← secretKeyRef{name: gitea-pg-app, key: password}
  [service]: DISABLE_REGISTRATION=true  REQUIRE_SIGNIN_VIEW=true
  [server]:  DISABLE_SSH=true  START_SSH_SERVER=false

# Raw policyRef payloads parse:
  platform/sveltos/manifests/forge/postgres.yaml   → Namespace/gitea, Cluster/gitea-pg
  platform/sveltos/manifests/kubewall/rbac.yaml    → Namespace/kubewall, ServiceAccount/kubewall,
                                                     ClusterRoleBinding/kubewall-view
```

### What I could NOT validate — **UNVERIFIED**

- **`kubectl apply --dry-run=client`** — blocked by
  `.claude/hooks/guard-destructive.py`, by design. I did not work around it. The
  jsonschema validation against the live CRD above is the substitute, and it is
  arguably stronger for the CRs (it checks the actual served schema); it does
  **not** check built-in-type schemas for the raw payload manifests.
- **The CNPG `Cluster/gitea-pg` CR against a real CNPG CRD.** No CNPG CRD exists
  on contraxia yet (that is what `26-infra-db` installs), so there was nothing to
  validate against. Mitigation: the CR is a field-for-field copy of the shape
  already reconciling in this repo at
  `platform/sveltos/manifests/coder/postgres.yaml`.
- **Whether Gitea's `SSL_MODE=require` matches CNPG's server TLS.** CNPG serves
  TLS with its own CA by default, so `require` (not `verify-full`) should
  connect. Not observed. If the Gitea pod logs a TLS handshake failure, drop to
  `disable` — the link is in-cluster.
- **Anything at runtime.** Nothing was applied. `fast-zfs` / `db-zfs` do not exist
  yet (`kubectl get sc` still shows only `longhorn`, `longhorn-static` — the ZFS
  migration had not landed at report time), so **the forge's PVCs will stay
  Pending until it does.** That is expected, not a fault.
- **Whether Tracks A/B claim `.241`** — §6.
- **Whether Track D owns the kagent chart** — §2, and why 24 is parked.

---

## 8. The forge cutover — WRITTEN UP, NOT EXECUTED

**Do not run this from an agent session.** It is a point of no return and the
user drives it. Adapted from devex `runbook-shamu.md` §7 and decision #11.

**Preconditions:** ZFS migration landed (`fast-zfs`, `db-zfs` exist); `26-infra-db`
and `21-forge` reconciled; `gitea-pg` Cluster healthy; Gitea pod Running and
reachable at `http://192.168.2.244:3000/`.

```bash
# 1. First admin. The chart creates none — that is deliberate (decision #8).
kubectl --context=admin@contraxia -n gitea exec deploy/gitea -- \
  gitea admin user create --admin \
    --username '<ADMIN_USER>' --email '<ADMIN_EMAIL>' \
    --password '<ADMIN_PASSWORD>' --must-change-password=true

# 2. PAT: log in at http://192.168.2.244:3000/ → Settings → Applications.
#    Registration is disabled and signin is required, so this admin is the only door.
#    Store it in a credential helper. NEVER in a git remote URL (see §5.4).

# 3. Create the target repos in the UI (or via API with the PAT), then
#    re-push each repo from the current OrbStack Gitea:
git remote add contraxia 'http://192.168.2.244:3000/<OWNER>/<REPO>.git'
git push contraxia --all
git push contraxia --tags

# 4. Verify BEFORE cutting over — compare refs on both forges:
git ls-remote gitea | sort > /tmp/old.refs
git ls-remote contraxia | sort > /tmp/new.refs
diff /tmp/old.refs /tmp/new.refs    # must be empty

# 5. ONLY THEN re-point consumers. The OrbStack Gitea stays a dormant spare;
#    do not delete it until the new forge has survived a few days.
```

⚠️ **What re-pointing means, and why it is the user's call, not an agent's:**
Flux on contraxia watches `GitRepository/homelab` →
`https://github.com/mershab99/homelab` (verified live). If any consumer is
re-pointed at the new forge, that forge becomes load-bearing for the delivery of
the entire homelab. `gitea dump` needs downtime and has no restore command, which
is why re-push beats volume migration at this repo count.

---

## 9. Fan-out: not used, and why

The brief authorised nested sub-workers. I ran none. The track decomposed into
six files that are all house-style-sensitive (Sveltos profile conventions, exact
pin rules, comment-as-decision-record style) and heavily interdependent through
one set of judgment calls — CAPVC's rejection determines the vcluster shape,
which determines whether `kubewall-capi-sync` exists, which changes KubeWall's
values. Splitting that across sonnet workers would have cost more in brief-writing
and style reconciliation than it saved. The parallel, mechanical part — verifying
seven chart pins against live registries — ran as batched `helm show chart` calls
in seconds.

I did use `orca orchestration ask` for the two genuine cross-track questions
(kagent ownership, `.241`); it timed out unanswered, and both are recorded above
as open items rather than guessed.

---

## 10. Open items for the coordinator

1. **Does Track D own the kagent chart?** `24-kagent-router.yaml` is parked
   pending the answer. Enable it, or delete it — never both owners.
2. **Is `192.168.2.244` free?** If not, move it *and* Gitea's `DOMAIN`/`ROOT_URL`.
3. **Rotate the Gitea PAT embedded in this worktree's `gitea` remote URL** (§5.4).
4. **Storage dependency:** nothing in `21-forge` can start until `fast-zfs` and
   `db-zfs` exist. Confirm with the migration-watch worker before reconciling.
5. **When the Orca cell lands**, revisit flux-operator-mcp's cluster-admin (§5.2).
6. `git push origin` was not run — per the brief, that is the coordinator's call
   after review. Pushed to `gitea` only.


---

## Coordinator amendment (2026-08-25, post-merge)

This track ran in parallel with three others and finished last, so two of its
choices collided with work already merged to `main`. Both were corrected by the
coordinator at merge time; the manifests in this repo are the corrected form.

1. **`20-infra-db.yaml` renamed to `26-infra-db.yaml`.** Track B had already
   merged `20-cpu-workspace.yaml`. The other numbers in this track (21-25) were
   free and were left alone.
2. **Gitea VIP moved `192.168.2.241` -> `192.168.2.244`.** All three tracks
   independently reasoned ".240 is taken, so .241 is first free" and all three
   claimed `.241`. The Orca cell kept `.241` because that address is baked into
   its `PAIRING_ADDRESS` and the Mac pairing instructions. Authoritative map:
   `docs/vip-allocation.md`. `ROOT_URL`, `DOMAIN`, and the PAT-creation URL in
   `21-forge.yaml` were rewritten to `.242` as well.

A steer carrying both instructions was sent to this worker before it completed,
but it finished without applying them - so treat the numbering/VIP text in the
body of this report as superseded by this section.

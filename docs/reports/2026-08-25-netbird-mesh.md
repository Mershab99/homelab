# TRACK G — self-hosted NetBird mesh: control plane on contraxia, operators on both clusters

Date: 2026-08-25 · Branch: `feat/netbird-mesh` · Profiles: `29-netbird-cp.yaml`, `30-netbird-operator.yaml`

> **Nothing in this report has been applied.** `kubectl apply` / `helm install` are
> denied by design; Sveltos is the write path. Everything marked **UNVERIFIED**
> could not be tested from here. In particular **no part of the mesh has been
> proven to carry traffic end to end**, and **every arrakis-side claim is
> unverified** because arrakis is down.

---

## 1. What shipped

| Path | What |
|---|---|
| `platform/sveltos/clusterprofiles/29-netbird-cp.yaml` | ClusterProfile `netbird-cp`, `persona=infra` (contraxia only) |
| `platform/sveltos/clusterprofiles/30-netbird-operator.yaml` | ClusterProfile `netbird-operator`, `persona In [infra, platform]` (both) |
| `platform/sveltos/manifests/netbird-cp/namespace.yaml` | ns `netbird` |
| `platform/sveltos/manifests/netbird-cp/server.yaml` | config-template ConfigMap, PVC, Deployment (+ render initContainer), Service |
| `platform/sveltos/manifests/netbird-cp/dashboard.yaml` | dashboard Deployment + Service |
| `platform/sveltos/manifests/netbird-cp/ingress.yaml` | Certificate + 3 Ingresses |
| `platform/sveltos/clusterprofiles/kustomization.yaml` | both profiles listed |

`docs/vip-allocation.md` is **unchanged on purpose** — this track claims **zero**
lan-pool addresses. Both Services are ClusterIP; everything public rides Track F's
single edge LB. No ARP probe was needed.

Validation actually run:

```
kustomize build platform/sveltos/clusterprofiles      → OK
kustomize build clusters/baremetal/infrastructure     → OK
python3 yaml.safe_load_all on all 6 new files         → OK
```

---

## 2. The big finding: the 4-container NetBird layout is retired upstream

devex `docs/decisions.md` #1 describes a hand-rolled translation of upstream's
Docker Compose into four Deployments — `netbirdio/management`, `netbirdio/signal`,
`netbirdio/relay`, `netbirdio/dashboard` — glued by a `management.json`, plus a
coturn. **That compose file is no longer upstream's blessed path.**

v0.77.x ships **`netbirdio/netbird-server`**: one binary running management +
signal + relay + STUN, configured by one small YAML. Evidence, all read at
`v0.77.1`:

- `infrastructure_files/getting-started.sh` — the current installer. Its generated
  compose has exactly two services, `dashboard` and `netbird-server`, the latter
  commented `# Combined server (Management + Signal + Relay + STUN)`.
- `combined/cmd/config.go` — `CombinedConfig`, whose doc comment states
  "Management: always runs locally… Signal: runs locally by default… Relay: runs
  locally by default… STUN: runs locally on port 3478 by default".
- `infrastructure_files/getting-started-with-zitadel.sh` now errors out with
  *"This legacy installation script has been retired and no longer runs."*

**Decision #1's packaging rule survives intact** — hand-rolled manifests, pinned
exactly, no upstream chart, because `netbirdio/helms` (appVersion 0.46.0) and
`cclloyd/helm-netbird` are both still behind. Only the component count changed:
4 Deployments + a coturn → **1 Deployment + 1 dashboard**, one PVC, no coturn.
The `netbird` namespace is still empty on contraxia, so nothing was migrated;
this is a fresh install of the current shape.

**Recommend amending devex decision #1** to record the combined-server pivot at
v0.77.x. I did not edit devex (read-only for this track).

---

## 3. Components, ports, exposure

Single public hostname: **`netbird.mershab.com`**.

| Component | Where it runs | Listens | Public path | Transport | Exposure |
|---|---|---|---|---|---|
| Management (gRPC) | `netbird-server` pod | `:8080` | `/management.ManagementService/*` | gRPC/h2c over TLS 443 | Track F edge → chisel (TCP) |
| Management (REST API) | same process | `:8080` | `/api/*` | HTTPS 443 | Track F edge → chisel (TCP) |
| Proxy service (gRPC) | same process | `:8080` | `/management.ProxyService/*` | gRPC/h2c over TLS 443 | Track F edge → chisel (TCP) |
| Embedded IdP (Dex) | same process | `:8080` | `/oauth2/*` | HTTPS 443 | Track F edge → chisel (TCP) |
| Signal (gRPC) | same process | `:8080` | `/signalexchange.SignalExchange/*` | gRPC/h2c over TLS 443 | Track F edge → chisel (TCP) |
| Relay | same process | `:8080` | `/relay`, `/ws-proxy/*` | WSS (`rels://…:443`) | Track F edge → chisel (TCP) |
| **STUN** | **not run** | — | — | **UDP** | **outsourced to public STUN — see §4** |
| Dashboard SPA | `netbird-dashboard` pod | `:80` | `/` (catch-all) | HTTPS 443 | Track F edge → chisel (TCP) |
| Healthcheck | `netbird-server` pod | `:9000` | — | — | in-cluster only (probes) |
| Metrics | `netbird-server` pod | `:9090` | — | — | in-cluster only, not scraped |
| WireGuard data plane | every peer | `:51820/udp` | — | UDP, peer↔peer | never touches contraxia |

The path split is a straight translation of upstream's own nginx template
(`render_nginx_conf` / `render_npm_advanced_config` in `getting-started.sh`), not
something I invented. Three Ingress objects rather than one because
`backend-protocol: GRPC` is a per-Ingress annotation in ingress-nginx and cannot
be scoped to a path.

Persistence: one PVC `netbird-data`, **5Gi, `fast-zfs`**, RWO, `strategy: Recreate`
(sqlite on RWO — never two pods). Holds the management store *and* the embedded
IdP's `idp.db`. **⚠️ The `tank` zpool does not exist yet, so this PVC and the pod
stay Pending.** Expected, not a fault — that is the operator's hand-run
`bootstrap/zfs/create-pool.sh`.

---

## 4. §UDP — the crux, answered plainly

**The honest answer: contraxia cannot serve a public UDP endpoint, so it does not
try. STUN is outsourced to public servers and the mesh keeps a TCP relay fallback
of its own. No coturn is deployed.**

### What actually needs UDP

1. **STUN (3478/udp)** — a peer asks "what does my address look like from
   outside?" to enable hole punching. devex decision #4 already booked the trap:
   *"STUN must observe the client's real source address… behind a chisel TCP
   tunnel it observes the tunnel endpoint instead — hole punching silently
   degrades to relay-only."* chisel tunnels TCP. A self-hosted STUN on contraxia,
   behind home NAT and reachable only through the tunnel, would be **worse than
   useless** — it would confidently hand every peer a wrong reflexive address.
2. **WireGuard data plane (51820/udp)** — peer↔peer. It **never traverses the
   control plane**, so contraxia's NAT is irrelevant to it. Two peers hole-punch
   directly.
3. **TURN** — not applicable. NetBird's own **relay** replaced TURN, and the relay
   speaks **WSS over TCP 443**, which rides chisel fine. `TURNConfig` no longer
   even appears in the combined config schema.

### What I did

`server.stuns` is set to two public STUN servers. In
`combined/cmd/config.go`, `applyRelayDefaults` starts the built-in STUN listener
**only when `stuns` is empty**, so setting it both (a) tells peers where to STUN
and (b) suppresses a local listener that could never be reached. No UDP Service,
no NodePort, no hostNetwork, no coturn, no port-forward — and no silent
degradation, because the thing that would have degraded is simply not deployed.

```yaml
stunPorts: []
stuns:
  - uri: "stun:stun.cloudflare.com:3478"
  - uri: "stun:stun.l.google.com:19302"
```

### What this costs

- **Privacy:** Cloudflare and Google observe the public IP of every peer that
  STUNs. They learn nothing about traffic or the mesh — STUN is a stateless
  "what's my IP" query — but it is a third party in the path and the user should
  know. If that is unacceptable, go to the upgrade path below.
- **Availability:** if both public STUN servers were unreachable, hole punching
  degrades and pairs fall back to the relay (TCP 443, through contraxia's
  uplink). Functional, higher latency, uplink-bound. Two independent providers
  make simultaneous failure unlikely.
- **Nothing else.** Peer-to-peer WireGuard, relay fallback and every control-plane
  path are unaffected.

### Upgrade path, if you want self-hosted STUN

You would need a **real public UDP endpoint**, which contraxia does not have.
Either:

- **Port-forward UDP 3478** on the home router to a LAN VIP on contraxia, put the
  NetBird server behind a UDP `type: LoadBalancer` Service on that VIP, delete the
  `stuns:` block and set `stunPorts: [3478]`. Requires a stable WAN address or
  DDNS for `netbird.mershab.com`, which today points at the DO droplet — so the
  STUN name would have to be a *second* hostname. Nothing else in the config
  changes.
- **Or keep a coturn/STUN on a VPS** (decision #4's original answer) and list it
  in `stuns:`.

Both are strictly more moving parts than public STUN buys back. I recommend
staying on public STUN until someone actually measures a hole-punching failure.

---

## 5. §Auth — recommendation: local users (embedded IdP), not Dex

**Recommendation: local users. Not close.**

NetBird ≥0.62 does not mean "a hand-rolled user table" — the management server
**embeds Dex in-process** (`management/server/idp/embedded.go`,
`EmbeddedIdPConfig`), serving OIDC at `https://netbird.mershab.com/oauth2` with
real PKCE, refresh tokens and TOTP MFA (`auth.mfaSession*` knobs exist). It is the
same IdP software the estate already runs, just co-located.

Why not federate to the estate Dex at `auth.mershab.com`:

1. **It is a circular dependency on the failure path.** Estate Dex runs on
   arrakis (`06-auth-stack.yaml`, `persona=platform`). arrakis's control plane is
   *hosted on contraxia*. So: to log into the tool whose entire purpose is
   reaching the estate when the estate is broken, the estate — and specifically
   the tenant whose control plane lives on the box you are trying to reach — has
   to already be up.
2. **It is not hypothetical.** arrakis is down as I write this. A Dex-federated
   mesh would be unusable today.
3. **The cost of local users is one more password**, and NetBird's embedded IdP
   supports MFA, so it is not a downgrade in strength.

Revisit only if the estate gains a second IdP hosted independently of arrakis.

### First admin — the only way in

There is **no self-signup** and **no `user create` CLI**. The server's `admin`
command tree exposes only `user change-password`, `user reset-mfa` and
`mfa enable|disable|status` (`management/cmd/admin/admin.go`). The single
bootstrap path is `auth.owner` in the config, which becomes a Dex
`StaticPassword`. Dex re-applies static passwords on every start, so it is
idempotent and the password stays config-managed.

**⚠️ `auth.owner.password` is a BCRYPT HASH, not a plaintext password**, despite
the field name — `combined/cmd/config.go:636` maps it straight to
`idp.OwnerConfig.Hash`, which Dex consumes as a hash. Feeding it plaintext
produces an account nobody can log into.

---

## 6. Why an initContainer renders the config (and why no secrets are in git)

The combined server reads its YAML with a plain `os.ReadFile` +
`yaml.Unmarshal` (`combined/cmd/config.go:451-456`). **No env expansion.** The
older `management.json` path *did* support substitution
(`util.ReadJsonWithEnvSub`, Go `text/template` over the env map — confirmed at
`util/file.go:234`), but that path is gone with the 4-container layout. There is
also no `*File` indirection and no env override for the secret fields — the only
`NB_*` variables in `combined/` and `management/server/store/` are
`NB_STORE_ENGINE_{POSTGRES,MYSQL}_DSN`, `NB_STORE_ENGINE_SQLITE_FILE`,
`NB_ACTIVITY_EVENT_*`, `NB_SQL_*` and `NB_PPROF_ADDR`.

So four secrets must physically be in the file. Putting the whole file in a
hand-applied Secret would take the reviewable part of the design (hostnames,
redirect URIs, the STUN decision, ports) out of git. Instead the config lives in
git as a ConfigMap with `@MARKER@` placeholders, and a **6-line `busybox:1.37.0`
initContainer** seds the values in from Secret `netbird-server-secrets` into an
emptyDir. Nothing secret is committed.

The substitution is the one piece of non-trivial logic here, so it has a check.
I extracted the committed ConfigMap and ran the exact initContainer script
against it:

```
PASS: no markers left
PASS: rendered config parses and every secret landed intact
        (authSecret, store.encryptionKey, auth.owner.email/password,
         sessionCookieEncryptionKey all byte-identical; stunPorts == [])
PASS: guard catches missing OWNER_BCRYPT     (negative case)
```

Values used were fakes chosen to exercise the delimiters: base64 containing `+`
and `/`, and a bcrypt hash containing `$` and `.`. **Known ceiling, marked with a
`ponytail:` comment in the manifest:** a secret containing `&`, `\` or `|` would
corrupt the sed replacement. base64, bcrypt and email alphabets contain none of
those. The guard `grep -q '@[A-Z_]\{3,\}@'` fails the init on any unsubstituted
marker, so a missing Secret key is a loud startup failure rather than an admin
account whose password hash is the literal string `@OWNER_BCRYPT@`.

**⚠️ `store.encryptionKey` must be supplied.** `EnsureEncryptionKey`
(`combined/cmd/config.go:783`) generates one when empty and only *logs* a warning
— unlike the old management path it does **not** write it back. Leaving it empty
means a new key every restart and an unreadable datastore.

---

## 7. Pinned versions and how each was verified

Every tag below was verified with `docker manifest inspect` / a registry tag list
on 2026-08-25. This is the check a round-1 defect skipped.

| Thing | Pin | Verification |
|---|---|---|
| NetBird combined server | `netbirdio/netbird-server:0.77.1` | `docker manifest inspect` → OK. `v0.77.1` (with `v`) → **MISSING**; the image tag has no `v` prefix even though the git tag does. |
| Dashboard | `netbirdio/dashboard:v2.91.1` | `docker manifest inspect` → OK, digest `sha256:186bc6cd126c…`. **Identical digest to `:latest`** — so v2.91.1 is the current shipping build. Note the GitHub *releases* list tops out at `v2.91.0` (digest `sha256:df6e0b1636…`); the tag exists without a release entry. |
| NetBird upstream version | 0.77.1 | GitHub releases: `v0.77.1` 2026-08-21, latest non-prerelease. devex's 0.77.0 (2026-08-13) is one patch stale. |
| Operator chart | `oci://ghcr.io/netbirdio/helm-charts/netbird-operator` **0.8.0** | `helm show chart` → version 0.8.0, appVersion v0.8.0, digest `sha256:d836ce83f06e…`. ghcr tag list → `[0.4.0 0.4.1 0.5.0 0.6.0 0.7.0 0.8.0]`. |
| Operator image | `ghcr.io/netbirdio/netbird-operator:v0.8.0` (chart default) | rendered from the chart, then `docker manifest inspect` → OK. |
| initContainer | `busybox:1.37.0` | `docker manifest inspect` → OK. |
| coturn | **not deployed** | n/a — see §4. |

**⚠️ Chart-location trap.** The obvious Helm repo,
`https://netbirdio.github.io/kubernetes-operator/index.yaml`, is **stale**: newest
entry chart 0.2.2 / appVersion 0.2.2, dated 2026-02-26, while the operator is at
v0.8.0 (2026-07-17). Using it would have silently installed a version ~6 releases
behind. The live chart is OCI-only and referenced only from the repo README.
`oci://ghcr.io/netbirdio/kubernetes-operator/...` and
`oci://ghcr.io/netbirdio/charts/...` both 404.

**Chart render check** — the exact values committed in `30-netbird-operator.yaml`
were rendered with `helm template`. 11 objects, no errors:
ServiceAccount, ClusterRole, ClusterRoleBinding, Role, RoleBinding, 2× Service,
Deployment, MutatingWebhookConfiguration, Certificate, Issuer. Confirmed in the
output: `--netbird-management-url=https://netbird.mershab.com`, the
`netbird-mgmt-api-key` secret ref, and the `namespaceSelector` from §8.
CRDs render from `crds/` (13 files), **not** `templates/` — so there is no
CRD-races-its-own-CRs deadlock like the other round-1 defect.

---

## 8. §Security — two chart hazards, one fixed, one accepted

### 8.1 FIXED: a cluster-wide pod webhook with `failurePolicy: Fail`

The chart's default `MutatingWebhookConfiguration` intercepts **every pod CREATE
cluster-wide**, with `failurePolicy: Fail` and **no `namespaceSelector`**. Its
`objectSelector` only exempts the operator's own pods.

On a **single-node** cluster that is a loaded foot-gun: if the operator pod cannot
run — node drained, image pull broken, or (very plausibly, right now) its
namespace blocked behind the missing zpool — the apiserver rejects **every pod
creation in the cluster** and the cluster cannot heal itself. Cilium, CoreDNS,
CAPI, Sveltos: all blocked.

**Fix applied:** `webhook.namespaceSelectors` scopes the webhook to namespaces
that opt in with `netbird.io/sidecar-injection: enabled`. Verified present in the
rendered `namespaceSelector.matchExpressions`. **No namespace carries that label
today**, so the blast radius starts at zero and grows only where someone
deliberately wants sidecar injection. `failurePolicy` stays `Fail` — inside an
opted-in namespace, a silently un-injected pod is worse than a rejected one.

### 8.2 ACCEPTED (flag for the user): cluster-wide Secret access

The operator's ClusterRole grants `secrets: get, list, watch, patch, update`
**cluster-wide**. `templates/rbac.yaml:181` gates that rule on
`or .Values.netbirdAPI.keyFromSecret .Values.clusterSecretsPermissions.allowAllSecrets`
— and `keyFromSecret` is mandatory, so the rule is **always** granted.
`clusterSecretsPermissions.allowAllSecrets: false` is a **no-op in 0.8.0**: I
rendered the chart with the flag both ways and diffed — zero difference. It is
not narrowable from values.

On contraxia that means read access to the `tenant-secrets` namespace, the
CAPI-generated arrakis kubeconfig, and Sveltos's own secrets.

Accepted because the user explicitly asked for the operator on both clusters.
Mitigations, in order of value:

1. **Scope the PAT to a NetBird *service user*, not a human owner account** — see
   §9. This bounds what an operator compromise buys inside NetBird.
2. Watch for an upstream release that honours `allowAllSecrets` or supports a
   namespaced secret scope, and revisit.
3. If cluster-wide Secret access is judged unacceptable, the alternative is devex
   decision #14's shape: a plain NetBird **routing-peer Deployment** with a scoped
   setup key and no operator, no PAT, no webhook. That is a smaller mesh feature
   set (no declarative Service→resource mapping) and is **not** what was asked
   for, so it is not what shipped.

### 8.3 What becomes reachable from the internet

`netbird.mershab.com` — the dashboard, the management REST API, the embedded
OIDC IdP, signal and relay. All behind the embedded IdP's authentication, all
over TLS. That is inherent: a mesh control plane that peers cannot reach is not a
mesh control plane. Nothing else this track adds is public, and this track claims
no LAN VIP.

---

## 9. Manual steps (placeholders only — never commit any of these)

### 9.1 Before the CP can start — `netbird-server-secrets` (ns `netbird`, contraxia)

Follows the repo's model: plaintext, hand-applied, gitignored (`secrets/README.md`).

```sh
kubectl --context admin@contraxia -n netbird create secret generic netbird-server-secrets \
  --from-literal=NETBIRD_RELAY_AUTH_SECRET='<REUSE the value already in tenant-secrets/netbird-management-secrets under NETBIRD_RELAY_AUTH_SECRET, or: openssl rand -base64 32>' \
  --from-literal=NETBIRD_DATASTORE_ENC_KEY='<REUSE that Secret'"'"'s NETBIRD_DATASTORE_ENC_KEY, or: openssl rand -base64 32>' \
  --from-literal=NB_IDP_SESSION_COOKIE_ENCRYPTION_KEY='<openssl rand -base64 32>' \
  --from-literal=NETBIRD_OWNER_EMAIL='<ADMIN_EMAIL>' \
  --from-literal=NETBIRD_OWNER_PASSWORD_HASH='<BCRYPT_HASH>'
```

Generate the bcrypt hash (never the plaintext) with:

```sh
htpasswd -bnBC 10 "" '<ADMIN_PASSWORD>' | tr -d ':\n'
```

Notes:
- The repo's existing Secret `netbird-management-secrets` (ns `tenant-secrets`)
  already holds usable values for the first two keys. I did **not** read it —
  reuse is the user's call. Its third key, `NETBIRD_TURN_PASSWORD`, is now
  **obsolete**: no coturn is deployed.
- **`NETBIRD_DATASTORE_ENC_KEY` is not recoverable.** Change it later and every
  stored credential in the datastore becomes unreadable.
- Keeping this as a hand-applied Secret rather than a
  `secrets/infrastructure/netbird/*.secret.yaml` file is fine; if you prefer the
  file form for rebuild-ability, add it there — it is gitignored.

### 9.2 First login

Once the pod is Running and Track F's edge resolves `netbird.mershab.com`:
browse to `https://netbird.mershab.com/`, log in as `<ADMIN_EMAIL>` with
`<ADMIN_PASSWORD>`. There is no other way in (§5). Enable TOTP immediately
(Settings → MFA) — the account is internet-reachable.

### 9.3 Operator PAT — `netbird-mgmt-api-key`, once per cluster

Only possible after 9.2. In the dashboard: **Team → Service Users → create →
generate access token**. Use a service user, not your owner account (§8.2).

```sh
# contraxia
kubectl --context admin@contraxia -n netbird create secret generic netbird-mgmt-api-key \
  --from-literal=NB_API_KEY='<NETBIRD_SERVICE_USER_PAT>'

# arrakis, once it is back
kubectl --context <ARRAKIS_CONTEXT> -n netbird create secret generic netbird-mgmt-api-key \
  --from-literal=NB_API_KEY='<NETBIRD_SERVICE_USER_PAT_ARRAKIS>'
```

Until it exists the operator Deployment sits in `CreateContainerConfigError` — a
contained, obvious failure.

**Why not propagate it through `10-tenant-secrets`:** Sveltos
`templateResourceRefs` are all-or-nothing — a missing source
`FailsNonRetriable` the *entire* profile. Adding a ref for a Secret that cannot
exist until a human logs into a dashboard would take cloudflare / dex / coder /
digitalocean propagation down with it. Once the PAT genuinely exists on mgmt,
adding the ref is safe and is the right follow-up.

### 9.4 Setup keys

Not shipped as CRs — an `NBSetupKey` cannot reconcile before the PAT exists, and
a permanently-failing CR is worse than a documented command. After 9.3, either
create them in the dashboard or declare them:

```yaml
apiVersion: netbird.io/v1alpha1
kind: NBSetupKey
metadata:
  name: <cluster>-peers
  namespace: netbird
spec:
  # reusable + ephemeral: peers keep no state and self-purge ~10min after
  # going offline, which is what you want for pod-shaped peers.
  ...
```

**UNVERIFIED** — the exact `spec` fields were not confirmed against the 0.8.0 CRD;
check `kubectl explain nbsetupkey.spec` once the CRDs are installed. Do not
copy-paste this into git as-is.

---

## 10. What Track F must route for me — the coordination contract

| Item | Value | Status |
|---|---|---|
| Hostname claimed | **`netbird.mershab.com`** | **`dig +short netbird.mershab.com @1.1.1.1` → empty (2026-08-25).** Track F must not also claim it. |
| IngressClass expected | **`nginx`** | **Does not exist yet:** `kubectl get ingressclass` → *No resources found*. My 3 Ingresses apply cleanly and sit inert until Track F lands it. |
| lan-pool VIP | **none** | `docs/vip-allocation.md` untouched. `.246`–`.250` remain free for others. |
| `loadBalancerClass` | **none, on any Service** | Both my Services are ClusterIP, so the operator cannot claim them and cannot flap anything. |
| Ports through the edge | **TCP 443 only** | No UDP is required from the edge (§4). No `tcp:` services block needed. |
| nginx features needed | per-Ingress `backend-protocol: GRPC`; long `proxy-read-timeout` | Both are stock ingress-nginx annotations, already used elsewhere in this repo. |
| nginx features NOT needed | `ssl-passthrough` | My Ingresses terminate TLS at the edge; passthrough on the arrakis edge is unrelated. |
| DNS publication | automatic | contraxia's external-dns is Running with `--source=ingress --source=service --domain-filter=mershab.com --txt-owner-id=homelab-mgmt --txt-prefix=edns-mgmt-` (verified from the live Deployment args). It will publish `netbird.mershab.com` off my Ingress once the edge LB has an address. **Do not hand-create the Cloudflare record.** |
| TLS | `letsencrypt-prod` ClusterIssuer | Verified `Ready` on contraxia. Cloudflare **DNS-01**, so the cert issues *before* the edge is reachable. One explicit `Certificate`, not per-Ingress annotations — three annotated Ingresses sharing a secretName would race and burn the 5-duplicate-certs/week limit. |
| chisel-operator | **must be installed on contraxia** | `chisel-operator-system` is **EMPTY** (verified: *No resources found*). Track F owns this. |

**⚠️ Magic-DNS collision to be aware of.** The management server sets its
peer-DNS domain to the `exposedAddress` host
(`combined/cmd/config.go applyManagementDefaults`), so mesh peers resolve as
`<peer>.netbird.mershab.com`. That is upstream's own behaviour (NetBird Cloud does
the same with `netbird.cloud`), and it is fine because there is no wildcard
record — but **nothing should ever publish a public record under
`*.netbird.mershab.com`**.

---

## 11. UNVERIFIED — the honest list

- **The mesh has not been proven to work end to end.** Nothing is applied. No
  peer has registered, no tunnel has been established, no hole punch has been
  observed. I cannot test this from here and do not claim it works.
- **Everything arrakis-side.** arrakis is DOWN (k0smotron CP hosted on contraxia,
  storage destroyed in the ZFS migration). It does **not appear** in
  `kubectl get sveltosclusters -A` on contraxia (only `mgmt/mgmt` and
  `projectsveltos/ai`). The `persona=platform` half of `30-netbird-operator.yaml`
  is written, selector-correct, and **completely unobserved**.
- The CP pod has never started: the `fast-zfs` PVC cannot bind until the `tank`
  zpool exists.
- The Ingresses have never been served: IngressClass `nginx` does not exist on
  contraxia yet (Track F).
- The ingress-nginx **path-precedence** claim (dashboard `/` losing to `/api`,
  `/oauth2`, `/relay`, and the gRPC prefixes across three Ingress objects) is
  taken from ingress-nginx's documented longest-prefix ordering and from
  upstream's own nginx config. **Not observed on a running controller.** If
  something 404s or lands on the dashboard, check this first.
- The `readinessProbe`/`livenessProbe` use `tcpSocket` on `:9000` rather than an
  HTTP path, because the healthcheck endpoint's path is not part of the
  documented surface and guessing wrong is a silent CrashLoop. A TCP probe is
  weaker but cannot produce a false failure.
- `NBSetupKey` spec fields (§9.4) were not checked against the installed CRD.
- Public STUN reachability from this network was not tested.
- **`docker manifest inspect` proves a tag resolves, not that the image runs on
  this cluster.** No image has been pulled onto contraxia.

---

## 12. Follow-ups worth someone's time

1. **Amend devex `docs/decisions.md` #1** — record the v0.77.x combined-server
   pivot and that the 4-container translation is retired upstream (§2). Not done
   here: devex is read-only for this track.
2. **Amend devex decision #4** — coturn is no longer the answer; the relay
   replaced TURN and STUN is outsourced (§4).
3. **Amend devex decision #14** — it rejected the operator to avoid an
   in-cluster PAT. The user overrode that; record the override and the
   cluster-wide-Secrets consequence (§8.2).
4. Once the PAT exists on mgmt, add it to `10-tenant-secrets` propagation so an
   arrakis rebuild needs no manual mesh step (§9.3).
5. Re-check `clusterSecretsPermissions.allowAllSecrets` on the next operator
   release — if upstream makes it real, set it `false`.
6. Consider whether `netbird.mershab.com` should be the *only* public surface of
   the estate long-term, with Gitea/KubeWall/Orca moving mesh-only behind it.
   That is the strongest security story available here and it is what the mesh
   was asked for. Out of scope for this track; it is Track F's hostname table.

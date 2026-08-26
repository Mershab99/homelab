# TRACK DR — the pivot ladder, evaluated

**Date:** 2026-08-26 · **Branch:** `dr-pivot-ladder` (Orca worktree; the brief
asked for `plan/dr-pivot-ladder` — the worktree was created without the prefix
and renaming it would detach the Orca workspace. Push it to gitea/github as
`plan/dr-pivot-ladder`.) · **Status:** PLAN ONLY.

> **Nothing here was applied.** No `kubectl`, no `helm`, no `talosctl`, no cloud
> API call was made during this track. `secrets/**` was never read — the
> permission layer denies it, and every secret below is named from
> `git ls-files` and from manifest references, never from content. Claims are
> either backed by a `file:line` quote from this repo or marked **`UNVERIFIED`**.
> Nothing about the *live* cluster state could be checked from this machine.

---

## 0. The answer, up front

**The pivot ladder is the right diagnosis and the wrong prescription.**

The bootstrap paradox in the brief is real, and it is worse than the brief
states (§2 below). But the ladder solves it at rung 2 — a whole Kubernetes
cluster in the cloud — when the actual failure is at rung -1: **there are no
backups. None. Not "Velero is pending B2" — the etcd snapshot CronJob that both
`docs/bootstrap.md` and `docs/runbooks/disaster-recovery.md` describe as
*running* does not exist in this repository.**

```
$ find . -iname '*etcd*'        →  (no results)
$ ls clusters/baremetal/infrastructure/
app-chart-sources.yaml  kustomization.yaml  namespaces.yaml
tenant-secrets.yaml     vcluster-autoregister.yaml
```

`docs/runbooks/disaster-recovery.md:16-19` says:

> - **etcd snapshot CronJob** on the bare-metal cluster runs `talosctl etcd
>   snapshot` daily, writes to a `fast-zfs` PVC, then `rclone copy` to an
>   off-box destination (configured in
>   `clusters/baremetal/infrastructure/etcd-backup/`).

That directory has never existed on `main`. `clusters/baremetal/infrastructure/kustomization.yaml`
lists four resources and none of them is a CronJob. `docs/bootstrap.md:316-324`
("## 12. etcd backup — Verify the etcd-backup CronJob fires") verifies a thing
that was never shipped. Combined with `04b-backup.yaml` being commented out at
`platform/sveltos/clusterprofiles/kustomization.yaml:16`, the true backup
inventory of this estate is:

| Artifact | Off-box copy today |
|---|---|
| Git (manifests, machineconfigs, **Talos PKI**) | ✅ `github.com/mershab99/homelab`, `main` — verified current (`git ls-remote origin` → `cd83bce`, == local `main`) |
| hub etcd (every Cluster CR, Sveltos binding, Flux source) | ❌ **none** |
| tenant (arrakis) etcd | ❌ **none** |
| PVC data (Orca cell 100Gi, Gitea + CNPG, media, vaultwarden) | ❌ **none** |
| filled `secrets/**/*.secret.yaml` | ❓ operator's laptop, unmanaged |
| 5 hand-created Secrets with **no template in git** | ❓ operator's memory (§3.1) |

So the honest framing: **you do not have a DR plan whose weak link is the
rebuild tier. You have no DR plan.** Building three rungs of cloud
infrastructure on top of zero backups buys nothing — every rung would boot
successfully into an empty cluster and then have nothing to restore.

**Recommendation:** do §7 Phase 1 (five items, one weekend, ~$0/mo net). Keep
exactly one rung of the ladder — rung 1, the cloud beachhead — and keep it for
the reason the brief almost found but did not name: **contraxia's Talos API and
kube-apiserver have no remote path at all** (§4.3). That is an *access* problem,
not a *rebuild* problem, and it is worth $6/mo — which the estate is already
paying, to a droplet doing nothing (§6).

Rungs 2 and 3 as described — a k3s/Talos cluster in cloud, `clusterctl move` —
**do not build.** §5 argues why the CAPI pivot is not even conceptually
applicable here, let alone literally.

---

## 1. Threat model — what you are actually recovering from

Six scenarios. The column that matters is the last one.

| # | Scenario | Blast radius | Covered today? |
|---|---|---|---|
| 1 | **Single disk loss** | one vdev leg | ⚠️ **Designed, not live.** `bootstrap/zfs/create-pool.sh` builds 7×2 mirrors + a warm spare, and that genuinely survives a disk. But `docs/runbooks/disaster-recovery.md:3-7` opens with "*As of 2026-08-25 the hub still runs Longhorn … there is no `tank` pool*". Whether `docs/runbooks/migrating-longhorn-to-zfs.md` has been executed since is **`UNVERIFIED`** from this machine. Until it has, single-replica Longhorn on one node ≈ no redundancy. |
| 2 | **Fat-fingered `kubectl` / bad delete** | one namespace or object | ⚠️ **Partly.** The GitOps loop is the real cure: delete a Deployment and Sveltos re-applies it from `main`. That covers *manifest* state well. It does **not** cover *data* — there are no ZFS snapshots scheduled (`docs/next-steps.md:63-65` lists snapscheduler as future work), so a `DROP TABLE` in the Gitea CNPG cluster is permanent. |
| 3 | **Bad GitOps commit reconciled estate-wide / ransomware** | everything, fast | ❌ **Not covered, and the GitOps loop is the attack path.** `bootstrap/flux/` sets `interval: 5m` on branch `main` with no manual gate. A bad merge to `main` propagates to both clusters in under five minutes. `git revert` fixes manifests; it does not un-delete a PVC that a reconciled `helmChartAction` tore down. |
| 4 | **Chassis / PSU death** (disks survive) | whole hub | ❌ **This is the scenario the runbook is written for and it cannot execute.** Steps 1-3 (`talosctl apply-config`, `bootstrap --recover-from=<snapshot.db>`) require a snapshot file. There is none. Best case today: rebuild Talos, re-bootstrap a *fresh* etcd, re-run `02-flux.sh`, re-apply the root ClusterProfile, and let Sveltos rebuild the estate from git — which actually works for everything **except** anything not in git: all PVC data, the arrakis etcd, and every hand-applied Secret. |
| 5 | **Site loss** (fire/flood/theft) | hub + disks + LAN + possibly the MacBook | ❌ **Not covered.** Same as #4 minus the disks. Note the one bright spot: `bootstrap/talos/{controlplane.yaml,worker.yaml,talosconfig}` are tracked **plaintext in a public repo** as an accepted risk (`docs/security-posture.md` §2), so the Talos identity survives site loss for free. See §3.2 — this is the single most DR-useful consequence of that decision and it should be recorded as such. |
| 6 | **"I am 3000km away and something is down"** | availability, not data | ❌ **Not covered at all, and this is the most likely scenario by frequency.** §4.3. |

**What the current runbook is actually good at:** #2's manifest half, and the
*ordering* of a rebuild (steps 3-9 of `disaster-recovery.md` are correct and
should be reused verbatim — see §6). What it is not good at: it asserts two
backups exist that do not, and every scenario from #3 down depends on them.

---

## 2. The bootstrap paradox — confirmed, and one layer deeper than the brief

The brief's three points hold. Verified:

1. **The agent tier lives on the cluster.** `platform/sveltos/manifests/orca-cell/orca.yaml:7-8` — "*the pod is a durable pet — its PVC holds every agent's OAuth state. Never scale it.*" `:99-113` — a 100Gi `fast-zfs` `volumeClaimTemplate`.
2. **No off-box copy of that PVC.** `platform/sveltos/clusterprofiles/kustomization.yaml:14-16` keeps `04b-backup.yaml` commented.
3. **Recovery is physically gated.** Single CP node, iDRAC `192.168.2.221` LAN-only.

**The layer the brief missed — the cell's own image is now on the cluster too.**
As of Track K (`04522a9`, 2026-08-26), `orca.yaml:65`:

```yaml
image: 192.168.2.244:3000/mershab/orca:v1.4.188
```

`192.168.2.244` is the Gitea LoadBalancer VIP — **the registry runs on
contraxia**. And `orca.yaml:45-46` pulls it with `imagePullSecrets: [gitea-pull]`,
a Secret hand-applied and, by design, never in git (`orca.yaml:41-44`). So the
recursion is now three deep: if contraxia dies you lose the cluster, the agents'
auth state, **and the artifact you would need to run an agent anywhere else**.

The mitigating fact is that the build context is in-repo (`images/orca/`,
`docs/runbooks/local-image-build.md` §2 — the Mac can build it), so this is
recoverable, just not *automatically*. It should be written down as a rung-0
step rather than discovered at 3am.

**A fourth recursion that turns out not to exist — worth stating so nobody
"fixes" it.** The forge is on contraxia (`21-forge.yaml`), and this worktree's
`gitea` remote points at `http://…@localhost:3000/mershab/homelab.git` (a
tunnel to it; the embedded PAT there is a real credential in `.git/config` and
is a separate hygiene item — **do not** copy that URL into any doc). But Flux
does **not** read from Gitea. `bootstrap/flux/` (the GitRepository):

```yaml
url: https://github.com/mershab99/homelab
ref: {branch: main}
```

GitHub is the source of truth for reconciliation, and it is current. **Gitea is
a convenience forge, not the forge of record for DR purposes** — despite
`21-forge.yaml:4` calling it "the forge of record". Losing contraxia does not
lose your GitOps repo. This is the estate's single strongest DR property and it
happened by accident; protect it by never repointing that GitRepository at
`git.mershab.com`.

---

## 3. Rung 0 — the MacBook, and the bootstrap-of-the-bootstrap

The brief asks what must be on the laptop. The answer is **much less than
expected**, because the estate's own security compromise handed DR a gift.

### 3.1 What is genuinely laptop-only (the real risk list)

Two tiers. Tier A has a template in git, so a lost copy means "re-obtain the
credential from its issuer and refill a known form". Tier B has **no template**,
so a lost copy means "reverse-engineer what the key was even called".

**Tier A — templated, recoverable-with-effort** (from `git ls-files secrets/`,
15 `*.example.yaml` → 15 filled `*.secret.yaml`, gitignored at `.gitignore:20`):

| Path (template) | Issuer to re-obtain from |
|---|---|
| `secrets/infrastructure/cert-manager/cloudflare-token.example.yaml` | Cloudflare |
| `secrets/infrastructure/external-dns/cloudflare-token.example.yaml` | Cloudflare |
| `secrets/infrastructure/chisel-operator/digitalocean-auth.example.yaml` | DigitalOcean |
| `secrets/infrastructure/chisel-operator/node-0{1,2}-credentials.example.yaml` | self-generated |
| `secrets/infrastructure/velero/velero-b2.example.yaml` | Backblaze (**not yet created at all**) |
| `secrets/infrastructure/dex/dex-config.example.yaml` | self — **bcrypt user db; losing this loses every account** |
| `secrets/infrastructure/grafana/grafana-oidc.example.yaml` | self (Dex client) |
| `secrets/infrastructure/coder/coder-oidc.example.yaml` | self (Dex client) |
| `secrets/infrastructure/minio/loki-minio.example.yaml` | self |
| `secrets/infrastructure/kagent/model-api-key.example.yaml` | Anthropic/OpenAI |
| `secrets/apps/{mediaserver,photoprism,vaultwarden}/*.example.yaml` | mixed |

**Tier B — hand-applied, no template, no recovery recipe.** These are referenced
by manifests but have no `*.example.yaml`, so nothing in the repo tells you their
key names or shape. This is the sharpest edge in the whole DR story:

| Secret | Referenced at | Notes |
|---|---|---|
| `flux-repo-pat` | `bootstrap/helm/02-flux.sh:36-44` | GitHub PAT. **Without it, nothing reconciles — this is the one bootstrap secret.** |
| `gitea-pull` | `orca-cell/orca.yaml:45-46` | Gitea PAT with registry read; also grants forge write (`orca.yaml:43-44`) |
| `gitea-runner-token` | `34-forge-runner.yaml` (`existingSecret`) | minted in the Gitea admin UI — which lives on the dead cluster |
| `netbird-server-secrets` | `29-netbird-cp.yaml:41-45` | 5 keys; the header lists names + `openssl rand` recipes, which is the only Tier-B secret that documents itself. Copy that pattern. |
| `github-mcp-token` | `orca-cell/orca.yaml:82` | `optional: true`, so non-blocking |
| `devbox-ssh-key` | `20-cpu-workspace.yaml:24-26` | derivable from `~/.ssh/id_ed25519.pub` |

### 3.2 What is *not* laptop-only, contrary to expectation

`git ls-files bootstrap/talos/` returns **`controlplane.yaml`, `worker.yaml`,
and `talosconfig`** as tracked files. `docs/security-posture.md` §2 is explicit
that these carry live PKI in the clear in a public repo and that this is a
decided, accepted risk. The DR consequence, which no document currently states:

- **`talosconfig` is not a laptop artifact.** Any machine with internet can
  `git clone` it and talk to a rebuilt node.
- **The machineconfig is not a laptop artifact.** `disaster-recovery.md:34-36`
  already relies on this ("*the committed rendered config*").
- **The kubeconfig is not needed off-box at all** — `talosctl kubeconfig`
  regenerates it (`docs/bootstrap.md:65-66`).

So the "seed of trust" is not the MacBook. It is `git clone
https://github.com/mershab99/homelab` plus a small credential bundle. That
single fact removes most of the reason to build rungs 2 and 3.

> Do not treat this as an argument to *keep* the PKI in the clear. It is an
> argument that, given it is already published and `security-posture.md` forbids
> rotating it, the DR plan should be honest about depending on it — and that the
> day it is rotated, the rotation runbook must add "put the new `talosconfig` in
> the off-box bundle" or DR silently regresses.

### 3.3 If the laptop is also gone (site loss + theft)

Walk it honestly:

1. Buy/borrow any machine. `brew install talosctl helm kubectl flux` per
   `docs/bootstrap.md:13-17`.
2. `git clone` the public repo → machineconfig + `talosconfig` in hand.
3. Log into GitHub, Cloudflare, DigitalOcean, Backblaze, Anthropic from the
   browser. **Every Tier-A credential is re-issuable from its provider.** They
   are not backups, they are re-mintable tokens — that distinction is what makes
   this survivable.
4. Re-run bootstrap steps 2-5. Get an empty but functioning estate.
5. Restore data from B2 — **which is why B2 has to exist, and is the whole of
   Phase 1.**

The genuinely unrecoverable items after step 4 are: `dex-config` (the bcrypt
user database — re-creatable, but every account is new), the arrakis etcd, and
all PVC data. Two of three are solved by turning on the backups that are
already written.

**The bootstrap-of-the-bootstrap therefore reduces to one question: how do you
authenticate to GitHub + your password manager from a borrowed machine?** That
is a 1Password/Bitwarden recovery-kit problem, not a Kubernetes problem, and it
is out of this repo's scope. Say so in the runbook and stop there. (The estate
runs its own Vaultwarden — `18-mershab-apps.yaml` — **on contraxia**. Do not
make it the store of the credentials needed to rebuild contraxia. If it already
is, that is the highest-priority item in this whole document.)

---

## 4. The ladder, rung by rung

### 4.1 Rung 0 — MacBook · $0 · RTO: minutes

Covered in §3. **Verdict: keep, and formalise.** Its one missing piece is a
scheduled off-box copy of the Tier-A/B secret bundle. `age`-encrypt the
directory to a key in the password manager, drop it in the same B2 bucket
Velero will use. One cron, ten lines. Not a rung — a `tar` command.

### 4.2 Rung 1 — cloud beachhead · $6/mo (**already being paid**) · RTO: minutes

This is the rung worth keeping, but **not for the reason the ladder proposes.**

The prior art is real and should be reused rather than reinvented:
`platform/sveltos/manifests/hub-edge/digitalocean-provisioner.yaml:14-23` already
provisions an `s-1vcpu-1gb` in `tor1` via chisel-operator, authenticating with
Secret `digitalocean-auth` / key `DIGITALOCEAN_TOKEN` (`:7-8`). The credential
exists, has a template (`secrets/infrastructure/chisel-operator/digitalocean-auth.example.yaml`),
and is already in the operator's bundle. **A DR beachhead needs zero new
credentials.**

The catch: a chisel-operator-provisioned droplet is not a jumpbox. It is created
*by the cluster*, for a tunnel, and it is destroyed by a finalizer when the
cluster's operator goes away — the exact failure documented in
`docs/reports/2026-08-25-contraxia-edge.md` §6, which stranded a droplet
*because* the operator was removed. **A DR beachhead must be provisioned
*outside* the cluster's control loop, or it dies in the same event you need it
for.** That means `doctl compute droplet create` from the laptop, or Terraform,
or click-ops — deliberately not GitOps. This is the one place where "not managed
by the cluster" is the feature.

**Its real job is not rebuilding — it is reachability.** See §4.3.

### 4.3 The finding that justifies rung 1: nothing on contraxia is remotely reachable

`platform/sveltos/manifests/hub-edge/ingresses.yaml:1-12` is emphatic:

> THE COMPLETE PUBLIC SURFACE OF CONTRAXIA. One file, on purpose. […] Nothing
> else on contraxia is public: the LAN VIP Services (cell/orca `.241`,
> workspaces devbox `.243`, gitea/gitea-http `.244`) are classless, so
> chisel-operator ignores them and they stay on 192.168.2.0/24 only.

Cross-reference what is *not* in that file:

| Endpoint | Remote path today |
|---|---|
| contraxia kube-apiserver `192.168.2.70:6443` | **none** |
| contraxia Talos API `:50000` | **none** |
| iDRAC `192.168.2.221` | **none** (LAN-only, per brief) |
| Orca cell `192.168.2.241:6768` | **none** |
| arrakis kube-apiserver | ✅ `k8s-home.mershab.com:6443` (`12-tenant-ingress.yaml:73-80`, L4 passthrough via the arrakis droplet) |
| Gitea, Orca UI | ✅ via hub droplet (`27-ingress-hub`) — `UNVERIFIED` live |

So the *tenant* is reachable from anywhere and the *hub that hosts the tenant's
control plane* is not. From 3000km away, if contraxia wedges, you have no
`talosctl`, no `kubectl`, no console, and no power control. You cannot even
reboot it.

`29-netbird-cp.yaml:8-20` is the estate's planned answer and its header already
makes a sharp version of exactly this argument — for auth:

> to log into the tool you use to reach the estate, the estate has to already be
> up […] That is a circular dependency that only bites on the day it matters.

That reasoning is correct and it applies one level up to the mesh itself:
**NetBird's control plane is scheduled on contraxia (`persona: infra`), so the
mesh dies with the hub too.** The header solved the IdP circularity and left the
hosting circularity in place. It is not this track's file to edit (Track G owns
it), but the plan should record the recommendation: *a mesh control plane whose
job is reaching a box must not run on that box.* Either host it on the
already-paid droplet, or accept that the mesh is a convenience path and keep a
dumb, independent SSH fallback.

**Minimum viable rung 1, therefore:** one `s-1vcpu-1gb` in `tor1`, provisioned
by hand, running sshd and a WireGuard peer to the house — enough to reach
`192.168.2.70:50000` and `:6443` and the iDRAC. That is a jumpbox. It is not a
new paradigm, it needs no operator, and it makes scenario #6 go from *impossible*
to *five minutes*.

### 4.4 Rung 2 — k3s vs Talos on that box · **verdict: do not build**

The brief asks for the argument. Here it is, and the conclusion is that the
question is moot.

*If* you needed rung 2, k3s would win on effort (single binary, any VPS, up in
90 seconds) and Talos would win on consistency (same paradigm as the estate,
same `talosctl` muscle memory, Sveltos-manageable). Talos on a generic VPS is
genuinely awkward — it wants to own the disk and PXE/ISO boot, and DO's custom
image path for Talos is a known-fiddly flow (**`UNVERIFIED`**, not attempted
here). k3s would be a second paradigm in an estate whose whole thesis is
Talos+Flux+Sveltos, and `docs/architecture.md` §5's hard rules exist precisely to
prevent that kind of sprawl.

**But you do not need a cluster to restore a cluster.** Trace what
`disaster-recovery.md` steps 1-5 actually require:

```
talosctl apply-config --insecure --nodes … --file controlplane.yaml
talosctl bootstrap --recover-from=<snapshot.db>
talosctl kubeconfig
bootstrap/helm/01-cilium.sh          # helm + kubectl
bootstrap/helm/02-flux.sh            # helm + kubectl
./secrets/apply.sh                   # kubectl
kubectl apply -f clusters/baremetal/sveltos-root.yaml
```

Four binaries — `talosctl`, `kubectl`, `helm`, `git` — and network reachability
to the node. That runs on a MacBook. It runs on a $6 droplet with a WireGuard
tunnel. It does **not** need a Kubernetes API server of its own at any point.
Standing up k3s to run `kubectl` against a *different* cluster is buying a
control plane to use as a shell.

The one thing rung 2 would add is a place for a *management* plane to live — CAPI
controllers, Sveltos — and §5 shows that specific idea does not work here.

**Verdict: skip rung 2 entirely.** If a future need appears (a second physical
site, a real multi-hub estate), revisit — and then pick Talos, because by that
point consistency beats convenience. Recorded so it is a decision, not an
omission.

### 4.5 Rung 3 — restore · **verdict: build this, and only this**

This is where the entire value is, and it is the rung that does not exist yet.

**3a. Hub etcd snapshots.** Ship the thing the runbook already claims. A CronJob
in `clusters/baremetal/infrastructure/etcd-backup/` running `talosctl etcd
snapshot` → PVC → `rclone copy` to B2. Design notes:

- It needs `talosconfig` in-cluster, i.e. a Secret with a **narrow-scoped**
  Talos role (`os:etcd:backup` if available — **`UNVERIFIED`**, check the Talos
  RBAC roles for the running version), never the admin `talosconfig`. Putting
  full admin Talos creds in a pod on the cluster is a lateral-movement gift.
- Ship it to **B2 directly**, not to a `fast-zfs` PVC that then gets copied. A
  snapshot whose only copy is on the box you are recovering from is not a backup.
  The PVC is a staging area at best.
- Alternative worth weighing: run the snapshot **from the laptop / rung-1
  jumpbox** on a schedule instead of in-cluster. It sidesteps the in-cluster
  credential problem entirely and is `talosctl etcd snapshot && rclone copy` in
  a `launchd` plist. Less elegant, strictly more robust — the backup mechanism
  should not share a failure domain with its subject. **Recommended.**

**3b. arrakis etcd.** k0smotron runs the tenant CP as a StatefulSet on
`db-zfs`. Its etcd PVC is inside `includedNamespaces: [tenants]` in
`04b-backup.yaml:76-79`, so enabling Velero covers it — *as a volume snapshot*,
not a consistent etcd dump. Good enough for a homelab, and worth a line in the
runbook saying so rather than implying it is an etcd backup.

**3c. Velero → B2.** `04b-backup.yaml` is complete and well-argued. It needs
exactly two things (`:14-17`): the B2 bucket/key filled into
`secrets/infrastructure/velero/velero-b2.secret.yaml`, and the three
`REPLACE_WITH_B2_*` placeholders at `:60-63`. Then uncomment
`kustomization.yaml:16`.

  One gap to close while you are in there: `includedNamespaces` is `[tenants,
  monitoring]` (`:76-79`). That does **not** include `cell` — the 100Gi Orca PVC
  the brief's whole argument rests on — nor `gitea`, `forge-runner`, or
  `workspaces`. The comment at `:77-78` explains the tenant-centric choice (it
  predates the shamu port that put real data on the hub), but the file is now
  out of date with the estate. Add `cell` and `gitea` at minimum.

**3d. Restore drill.** `.taskfiles/backup.yml` already has `trigger`, `list`,
`describe`, `restore`. `04b-backup.yaml:19-20`: "*An untested restore path is a
hypothesis.*" Correct. Calendar it quarterly, per `docs/next-steps.md:68-69`.

---

## 5. Is CAPI `clusterctl move` literally reusable? No.

The brief asks. Worth answering precisely, because the analogy is seductive.

`clusterctl move` relocates CAPI objects (Cluster, Machine, and their providers'
CRs) from one management cluster to another. For that to be a DR primitive here,
contraxia would have to be a CAPI-*managed* cluster. It is not — contraxia is
Talos installed by hand (`docs/bootstrap.md` §2), and CAPI on it exists to manage
**arrakis** (`05-capi-stack.yaml`, `10-tenant-arrakis.yaml`).

So a pivot would move the *management of arrakis* to a cloud cluster. Then:

- arrakis's control plane is **k0smotron pods** — they would be recreated *on the
  cloud cluster*, which has no `db-zfs`, no tank pool, and no route to the LAN.
- arrakis's workers are **KubeVirt VMs on contraxia's hypervisor**
  (`docs/bootstrap.md:243-252`). CAPK would find them unreachable and, worse,
  might try to reconcile them into existence on a cluster with no KubeVirt.
- `kubevirt-csi` runs in Mode B on mgmt against the CAPI-minted
  `arrakis-kubeconfig` (`docs/bootstrap.md:188-190`) — that whole path assumes
  co-location.

That is not a DR pivot; it is a full estate migration to the cloud, executed
under duress, with the hypervisor missing. **Conceptually useful** — "each tier
can rebuild the one above it" is a good mental model and the reason the
GitHub-is-source-of-truth property matters. **Literally unusable** — do not put
`clusterctl move` in a runbook.

The genuine "pivot" this estate already has is better than CAPI's: `kubectl
apply -f clusters/baremetal/sveltos-root.yaml` against a fresh cluster
reconstitutes the entire management plane from git in one command
(`disaster-recovery.md:50-54`). That is the pivot. It already works. It just has
nothing to restore *into*.

---

## 6. Reuse vs replace — what changes in the existing docs

**Reused verbatim, no change:**

- `disaster-recovery.md` steps 3-9 — the rebuild ordering is correct.
- `bootstrap/helm/01-cilium.sh`, `bootstrap/helm/02-flux.sh` — both idempotent,
  both re-runnable on a fresh node, exactly as step 3 says.
- `clusters/baremetal/sveltos-root.yaml` + the relabel from `docs/bootstrap.md`
  step 5 — the one-command management-plane restore.
- `./secrets/apply.sh` — re-runnable by design (`docs/bootstrap.md:183-186`).
- `04b-backup.yaml` — the manifest is right; it is only unlisted.
- `.taskfiles/backup.yml` — the restore verbs already exist.
- `manifests/hub-edge/digitalocean-provisioner.yaml` — the DO credential
  pattern, reused for the jumpbox (§4.2). Not the object.

**Replaced / corrected:**

| Where | What is wrong | Fix |
|---|---|---|
| `disaster-recovery.md:16-19` | claims an etcd CronJob that does not exist | either ship it (§4.5a) or mark **NOT IMPLEMENTED** — today the doc actively misleads |
| `disaster-recovery.md:23-26` | claims tenant snapshots "are shipped off-box" | same; they are not |
| `disaster-recovery.md:37-40` | `bootstrap --recover-from=` | unreachable step while 3a is unimplemented |
| `docs/bootstrap.md:316-324` | verifies a CronJob that was never shipped | drop or gate on 3a |
| `04b-backup.yaml:76-79` | `includedNamespaces` predates the shamu port | add `cell`, `gitea` |
| `disaster-recovery.md` (missing) | no mention that `talosconfig`/machineconfig come from git | add §3.2 as a step-0 note — it is the fastest part of any recovery |
| `disaster-recovery.md` (missing) | no mention that the cell image is on the dying cluster | add "rebuild from `images/orca/`" as a rung-0 step (§2) |

**Relationship to Track J (`feat/arrakis-devbox`, brief `15-ARRAKIS-DEVBOX.md`):**
The brief is right that it is "rung 1 pointed inward". Two notes, both hands-off:
`git diff main...feat/arrakis-devbox` is currently **empty** (the branch is an
ancestor of `main` at `84618c7`), so nothing of Track J exists to conflict with
yet — and `15-ARRAKIS-DEVBOX.md` is not present in
`~/.agents/briefs/dr-pivot-2026-08-26/`, so its contents are **`UNVERIFIED`**
here and this document does not rely on them. The relationship: Track J's devbox
is *inside* the failure domain (a StatefulSet/VM on the estate) and so is a
workspace-offload play, not a recovery play. A DR jumpbox must be outside. They
should stay separate boxes; the only thing they should share is the operator's
SSH public key. **Do not merge the two ideas** — the moment the DR jumpbox gains
a dependency on the estate, it stops being rung 1.

---

## 7. Cost, and the decision

### Running cost at rest

| Option | $/mo | Note |
|---|---|---|
| Do nothing | $0 | current state, plus §6 waste below |
| **Orphaned DO droplet, billing now** | **$6** | `docs/reports/2026-08-25-contraxia-edge.md` §6 — alive at `165.227.32.29`, ~20 days, nothing attached |
| arrakis edge droplet | ~$6 | in use, `k8s-home.mershab.com` |
| hub edge droplet (Track F) | ~$6 | in use once `27-ingress-hub` reconciles |
| **B2 for etcd + PVC backups** | **~$0.50–3** | B2 ≈ $6/TB/mo; etcd snapshots are MB. Real cost is media PVCs — exclude them |
| **DR jumpbox (rung 1)** | **$6, or $0 net** | repurpose the orphan instead of destroying it |
| rung 2 cloud cluster | $12–24 | 2GB minimum for k3s + control plane overhead. **Not recommended** |

**The whole Phase 1 is cash-flow-neutral or better.** You are already paying $6/mo
for a droplet doing nothing; redirecting it to the jumpbox costs $0 more, and B2
for what actually needs backing up is single-digit dollars.

> Caveat on the orphan: `contraxia-edge` §6 offers path A (let profile `02`
> adopt it, because the CR name matches exactly) and path B (destroy and
> re-provision, recommended there). Repurposing it as a DR jumpbox is a **third**
> path and conflicts with A — the ExitNode CR still has
> `exitnode.chisel-operator.io/finalizer`, so when chisel-operator returns to
> contraxia it will try to manage or destroy that droplet. **Do not repurpose
> that specific droplet.** Take path B (destroy it, −$6) and create the jumpbox
> as a fresh, cluster-invisible droplet (+$6). Net $0, no finalizer fight. This
> is Track F's object to delete, not this track's.

### Phase 1 — small enough to do this month

Ordered by value per hour. Items 1-3 are the actual DR plan; 4-5 are the cheap
insurance around it.

1. **Stop lying in the runbook** (30 min, $0). Edit `disaster-recovery.md` and
   `docs/bootstrap.md` §12 to say the etcd CronJob is NOT IMPLEMENTED and PVCs
   have NO off-box copy. A DR doc that overstates coverage is worse than no doc —
   it stops you from noticing. **Do this first, before anything else, because it
   is the item most likely to be skipped once the real work starts.**

2. **Turn on Velero → B2** (2 hrs, ~$1/mo). Create the B2 bucket + app key. Fill
   `secrets/infrastructure/velero/velero-b2.secret.yaml`. Replace the three
   placeholders at `04b-backup.yaml:60-63`. Add `cell` and `gitea` to
   `includedNamespaces`. Uncomment `kustomization.yaml:16`. Then actually run
   `task backup:restore` into a scratch namespace — an untested restore is a
   hypothesis.

3. **etcd snapshots off-box** (2 hrs, $0). Take the laptop/jumpbox-side variant
   from §4.5a: a scheduled `talosctl etcd snapshot` + `rclone copy` to the same
   B2 bucket. Skip the in-cluster CronJob for now — it needs a scoped Talos role
   that has not been verified to exist, and the external version has a strictly
   better failure domain. Ship the CronJob later if the schedule proves
   unreliable.

4. **Close the Tier-B secret gap** (1 hr, $0). Add `*.example.yaml` templates for
   `flux-repo-pat`, `gitea-pull`, `gitea-runner-token`, `github-mcp-token`. Copy
   the self-documenting style of `29-netbird-cp.yaml:41-45`, which names its five
   keys and their `openssl rand` recipes inline. Then `age`-encrypt the filled
   `secrets/` tree to a password-manager key and put it in B2 alongside the etcd
   snapshots. **And verify the credentials needed to rebuild contraxia are not
   stored solely in the Vaultwarden that runs on contraxia** (§3.3).

5. **The jumpbox** (1 hr, $0 net). Destroy the orphan per `contraxia-edge` §6
   path B. Create one fresh DO droplet by hand — sshd, a WireGuard peer to the
   house, `talosctl`/`kubectl`/`helm`/`git` installed, the operator's SSH key,
   nothing else. Never referenced by any manifest in this repo. Document its IP
   in the runbook. This is the entire ladder, and it is one box.

**Explicitly not in Phase 1, and not in Phase 2 either:** a cloud Kubernetes
cluster, `clusterctl move`, a second GitOps paradigm, any new operator, any new
CRD, and anything that makes the recovery path depend on the estate being partly
alive.

### The one-sentence version

Enable `04b-backup.yaml`, ship etcd snapshots from *outside* the cluster, keep
an off-box copy of `secrets/` — and buy one $6 jumpbox because contraxia
currently has no remote hands at all. The other two rungs are a cluster you
would use as a shell.

---

## 8. Open questions for the operator

1. **Has the Longhorn→ZFS migration run?** `disaster-recovery.md:3-7` says no as
   of 2026-08-25. Everything in threat #1 depends on the answer. Not checkable
   from here — **`UNVERIFIED`**.
2. **Where do the credentials that rebuild contraxia live?** If the answer is
   "Vaultwarden", that is a same-day fix and it outranks everything in Phase 1.
3. **Does Talos ship a scoped `os:etcd:backup` role on the running version?**
   Decides whether §4.5a can ever be a safe in-cluster CronJob. **`UNVERIFIED`**.
4. **Should `29-netbird-cp.yaml` move off contraxia?** Track G's call, not this
   track's. §4.3 makes the case; recorded, not acted on.
5. **The `gitea` remote in this worktree's `.git/config` embeds a plaintext PAT
   in the URL.** Out of scope here and not touched, but it belongs on the
   hygiene list next to `docs/next-steps.md` § "Hygiene / debt".

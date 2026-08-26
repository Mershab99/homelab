# Arrakis devbox — SSH box + Orca server on the tenant cluster (Track J)

Branch `feat/arrakis-devbox`. Profile **32**. Written 2026-08-26.

> "Lets use a ssh devbox with orca right now on arrakis as well to offload some
> orca workspaces, things are getting heavy"

**Status: manifests written, validated, committed. Nothing applied** — the git
write path is the only write path (Sveltos applies). One hand-applied Secret and
the Orca account/pairing steps are manual by design; both are in §7.

**Headline finding, read this before anything else:** the arrakis worker VM is
**4 cores / 7.66 GiB**. The MacBook's OrbStack VM this box is supposed to
relieve has 12 GiB. So this delivers a real *CPU* offload and a *negative*
memory offload. It is a useful always-on tenant-side box; it is **not** where
heavy Orca workspaces should go. The heavy box is contraxia's
`20-cpu-workspace` devbox (12 vCPU / 32 GiB). Detail and the one-field fix in §5.

---

## 1. What shipped

| File | What |
|---|---|
| `platform/sveltos/clusterprofiles/32-arrakis-devbox.yaml` | ClusterProfile `arrakis-devbox`, `persona: platform`, `dependsOn: [tenant-baseline]` |
| `platform/sveltos/manifests/arrakis-devbox/namespace.yaml` | Namespace `workspaces` |
| `platform/sveltos/manifests/arrakis-devbox/bootstrap.yaml` | ConfigMap `devbox-bootstrap` — the start-up script |
| `platform/sveltos/manifests/arrakis-devbox/devbox.yaml` | StatefulSet `devbox` + ClusterIP Service `devbox` |
| `platform/sveltos/clusterprofiles/kustomization.yaml` | `32-arrakis-devbox.yaml` added to the resource list |
| `docs/runbooks/gitea-token-rollover.md` | the forge-cutover runbook (§8) |

Validation actually run — the guard denies `kubectl apply`, including
`--dry-run`, so this is static plus one container smoke test:

```
$ kustomize build platform/sveltos/clusterprofiles       # OK
$ kustomize build clusters/baremetal/infrastructure      # OK
$ python3 -c "yaml.safe_load_all(...)"  x4 files         # OK
$ bash -n bootstrap.sh                                   # OK  (script extracted from the ConfigMap)
$ shellcheck -s bash bootstrap.sh                        # rc=0, no findings
```

`kubeconform`/`kubeval` are not installed on this machine — **no schema
validation was performed. UNVERIFIED.**

No VIP was claimed. `docs/vip-allocation.md` is untouched on purpose: this track
uses no LoadBalancer (§4).

---

## 2. Arrakis ground truth, re-verified 2026-08-26

Every command below was run and its output seen.

**The kubeconfig trap is real and unchanged.** Context `admin@arrakis` points at
`k8s-home.mershab.com:6443`, the dead DigitalOcean droplet. The working form is:

```sh
kubectl --context admin@arrakis --server=https://192.168.2.240:6443 --request-timeout=30s get nodes
```

I did **not** edit the user's kubeconfig. Two ways to make this permanent, both
outside this track:

- Repoint the context at the LAN VIP:
  `kubectl config set-cluster <cluster-name> --server=https://192.168.2.240:6443`
  — the CP serving cert already covers the VIP (this is how the override works),
  but it makes the context LAN-only.
- Restore the droplet via Track F's chisel work, which is what
  `12-tenant-ingress.yaml` was built to do (nginx `tcp: {"6443": "default/kubernetes:443"}`
  behind a chisel-classed LB). That restores off-LAN kubectl too.

**Cluster state after the coordinator cleared the Cilium blocker (§9):**

```
$ kubectl … get nodes
NAME                          STATUS   ROLES    AGE     VERSION
arrakis-general-57f89-7b6cj   Ready    <none>   2m54s   v1.36.2+k0s

$ kubectl … get pods -n kube-system
cilium-ck28d                       1/1 Running
cilium-envoy-h6vs7                 1/1 Running
cilium-operator-67dc595bcc-cpl5r   1/1 Running
coredns-84958f7b59-q4btl           1/1 Running
konnectivity-agent-nmmhg           1/1 Running
kube-multus-ds-vlm7r               1/1 Running
kube-proxy-bp44c                   1/1 Running
metrics-server-d987bf784-9n675     1/1 Running

$ kubectl … get pods -n kubevirt-csi-driver
kubevirt-csi-node-fpsbl   3/3 Running

$ kubectl … get sc
NAME                 PROVISIONER       RECLAIMPOLICY   VOLUMEBINDINGMODE      EXPANSION
kubevirt (default)   csi.kubevirt.io   Delete          WaitForFirstConsumer   true
```

**Sveltos selector.** Profiles reach arrakis through the CAPI `Cluster`, not a
`SveltosCluster` — there is no arrakis `SveltosCluster` object:

```
$ kubectl --context admin@contraxia get sveltoscluster -A --show-labels
mgmt/mgmt            persona=infra,tier=platform,needs.*=true…
projectsveltos/ai    persona=ai

$ kubectl --context admin@contraxia get clusters.cluster.x-k8s.io -A --show-labels
tenants/arrakis   …   Provisioned   persona=platform,tier=workload,sveltos.projectsveltos.io/type=tenant
```

So `clusterSelector: {matchLabels: {persona: platform}}` is correct and selects
arrakis only. Confirmed against the profiles that already land there
(`06-auth-stack`, `12-tenant-ingress`, `11-tenant-baseline`).

**Nested virt is off the table, as briefed.** The arrakis worker is itself a
KubeVirt VM on contraxia (`KubevirtMachineTemplate/arrakis-general`,
`tenants/arrakis/infra/machinetemplate-general.yaml`). A `VirtualMachine` on
arrakis would be a VM inside a VM. Hence a StatefulSet — the one structural
divergence from `20-cpu-workspace.yaml`.

---

## 3. Decision 1 — the image: **stock `ubuntu:24.04` + a runtime bootstrap script**

Brief's option **(b)**, recommended and taken.

### The problem with option (a)

`ghcr.io/mershab99/orca:v1.4.188` is what `19-orca-cell.yaml` uses and it is a
**private** ghcr package. This Mac's registry credential and `gh` session both
belong to `mershab-integratrace`, not `mershab99`
(`docs/reports/2026-08-25-orca-cell-contraxia.md` §B1). `orca-0` on contraxia is
`ImagePullBackOff` on exactly that today. Reusing it here ships a second pod
that cannot start, plus a second hand-applied `ghcr-pull` Secret to forget.

### Why (b) works: every ingredient is public

The one fact that makes this viable — the Orca `.deb` upstream is a **public**
GitHub release asset. Verified unauthenticated, 2026-08-26:

```
$ curl -sIL -o /dev/null -w '%{http_code}\n' \
    https://github.com/stablyai/orca/releases/download/v1.4.188/orca-ide_1.4.188_amd64.deb
200
```

So the container needs no registry credential at all. `bootstrap.yaml`
reproduces the RUN layers of devex `images/orca/Dockerfile` at container start:
apt toolchain + `openssh-server` + the 13 Chromium sonames the `orca-ide` deb
fails to declare (`libnspr4` … `libgbm1` — copied verbatim; devex derived them
empirically from `ldd`, do not prune them), Node 22 + the agent CLIs, then the
deb.

### Version pins, all verified

| Pin | Value | Evidence |
|---|---|---|
| `ORCA_VERSION` | `1.4.188` | `orca status --json` → `result.runtime.appVersion = 1.4.188`; `stablyai/orca` latest release = `v1.4.188`. **Must equal the Mac's version — pairing is refused across an app-version gap.** Bump both together. |
| `CLAUDE_CODE_VERSION` | `2.1.235` | `npm view @anthropic-ai/claude-code@2.1.235 version` → `2.1.235`, rc=0 |
| `CODEX_VERSION` | `0.148.0` | `npm view @openai/codex@0.148.0 version` → `0.148.0`, rc=0 |

The agent-CLI pins are devex's, kept rather than bumped to latest (`2.1.246` /
`0.149.1`): that exact triple is the combination already known to install
cleanly on `ubuntu:24.04`.

### What (b) costs, and the exit

~500 MiB of apt+npm **on every pod start**. Cold start is minutes, not seconds
— hence a `startupProbe` with a 10-minute budget (60 × 10s) rather than a
readiness probe with a guessed `initialDelaySeconds`. The pod is a pet that
restarts rarely, so this is the right trade today.

The exit is one line: bake the script into an image, push it to the **Gitea
registry Track F is standing up**, and swap `image: ubuntu:24.04` + the
`command:` for that tag. That also closes the loop with §8's runbook — the same
forge, no ghcr credential ever needed. Option (c) (build-and-push to ghcr) needs
`Mershab99` credentials nobody here has; it stays a placeholder.

### Smoke test — run for real, and it **found a bug**

The script was executed against `ubuntu:24.04` under `--platform linux/amd64` on
this Mac (qemu-emulated), twice.

**Run 1 — the install path.** Reached, in order:

```
[devbox] apt: sshd + toolchain + the Chromium shared libraries Orca's deb does not declare
[devbox] node 22 + agent CLIs
[devbox] orca 1.4.188
  …
  Setting up orca-ide (1.4.188) ...
[devbox] user dev -> /data/home
useradd: UID 1000 is not unique
EXIT=4
```

So the package list resolves, Node 22 + both agent CLIs install, and **the Orca
deb installs cleanly** — then the script died. `ubuntu:24.04` ships a stock
`ubuntu` account **at uid 1000**, so `useradd --uid 1000` collides. devex's
Dockerfile has `userdel -r ubuntu 2>/dev/null || true` for exactly this and I had
not carried it over; the guard I did write (`id -u dev || useradd`) does not
catch it, because the conflicting account is not named `dev`. Unfixed, this is a
CrashLoop on every start. Fixed in `bootstrap.yaml`; `|| true` keeps it
idempotent on a warm restart.

**Run 2 — the user/sshd/exec tail, with the fix and a stubbed `orca-ide`**, plus
a real key login:

```
[devbox] user dev -> /data/home
[devbox] sshd on :22 (pubkey only, user dev)
[devbox] orca serve :6768, advertising 127.0.0.1
ORCA_STUB started as uid 1000 HOME=/data/home args: serve --port 6768 --pairing-address 127.0.0.1

=== who is uid 1000 ===   dev:x:1000:1000::/data/home:/bin/bash
=== sshd running? ===     656 /usr/sbin/sshd -e -o HostKey=/data/ssh-host/… -o PermitRootLogin=no
                              -o PasswordAuthentication=no -o AllowUsers=dev …
=== host key ===          -rw------- root root /data/ssh-host/ssh_host_ed25519_key
=== authorized_keys ===   -rw------- dev  dev  /data/home/.ssh/authorized_keys

=== REAL LOGIN TEST ===   LOGIN OK: user=dev uid=1000 home=/data/home pwd=/data/home
                          root                       # `sudo -n id -un` — passwordless sudo works
                          ssh rc=0
=== ROOT LOGIN MUST FAIL ===
                          root@127.0.0.1: Permission denied (publickey).
```

Confirmed by that run: the `userdel` fix, the host key landing on the PVC path
(stable `known_hosts` across restarts), `authorized_keys` built from the Secret
mount at `0600 dev:dev`, **a real pubkey login as `dev`**, passwordless sudo,
root login refused, and `setpriv` handing Orca **uid 1000 with
`HOME=/data/home`** and the right argv. The `sshd -o …` form does take effect —
that was the least certain part of the design.

**Run 3 — the unmodified script, real Orca binary, end to end.** It crashed, and
this one is the important find:

```
[devbox] orca serve :6768, advertising 127.0.0.1
Failed to move to new namespace: PID namespaces supported, Network namespace
  supported, but failed: errno = Operation not permitted
[FATAL:content/browser/zygote_host/zygote_host_impl_linux.cc:207] Check failed
Orca serve exited via SIGTRAP.
```

Chromium's zygote sandbox needs unprivileged user namespaces and does not get
them. So the `ORCA_NO_SANDBOX` escape hatch is not hypothetical — it is the
normal path. **And that escape hatch was broken.** devex's `entrypoint.sh`, and
therefore `19-orca-cell.yaml`'s documented remedy, pass `--no-sandbox` as an
argv element. Orca's CLI rejects it:

```
$ orca-ide --no-sandbox serve --port 6768 --pairing-address 127.0.0.1
Unknown flag --no-sandbox for command: serve
Next step: Valid flags: --environment, --help, --json, --mobile-pairing,
  --no-pairing, --page, --pairing-address, --pairing-code, --port,
  --project-root, --recipe-json
```

Setting `ORCA_NO_SANDBOX=1` on the existing cell would therefore turn a crash
into a *different* crash. **Track A should be told.** The knob that does work is
Electron's own `ELECTRON_DISABLE_SANDBOX=1`, set as an environment variable and
set *conditionally* — Electron tests the variable for presence, so
`ELECTRON_DISABLE_SANDBOX=0` also disables the sandbox.

**Run 4 — with the fix, warm-restart path, real Orca:**

```
[devbox] user dev -> /data/home
[devbox] sshd on :22 (pubkey only, user dev)
[devbox] orca serve :6768, advertising 127.0.0.1
[serve] orca CLI install: installed (/data/home/.local/bin/orca-ide)
Orca server ready
Bound endpoint:      ws://0.0.0.0:6768
Advertised endpoint: ws://127.0.0.1:6768
Pairing URL:         orca://pair?code=eyJ2IjoyLCJlbmRwb2ludCI6IndzOi8vMTI3LjAuMC4xOjY3Njgi…

$ ssh -i <key> dev@127.0.0.1 'echo …; claude --version; codex --version'
LOGIN OK uid=1000 home=/data/home
2.1.235 (Claude Code)
codex-cli 0.148.0
```

Container stayed **Up**. That is the whole design proven in one process: sshd
and Orca coexisting, the warm-restart path (pre-existing `dev` user and host
key) taking the idempotent branches, both agent CLIs at their pinned versions,
Orca binding `0.0.0.0:6768` while advertising `PAIRING_ADDRESS`, and a real
pairing URL. The pairing code decodes to `{"v":2,"endpoint":"ws://127.0.0.1:6768",…}`
— i.e. `PAIRING_ADDRESS=127.0.0.1` produces exactly the endpoint the Mac reaches
through the port-forward.

Run 3's `WARNING: no keys under /etc/devbox-ssh` line also confirms the
missing-Secret branch degrades instead of crashing, as intended.

One harness bug worth recording so nobody repeats it: run 4 initially still
crashed because `docker commit` bakes the source container's `-e` values into
the image, so `ORCA_NO_SANDBOX=0` was inherited and `${ORCA_NO_SANDBOX:-1}`
never defaulted. The script was right; the test was poisoned.

---

## 4. Decision 2 — exposure: **ClusterIP + `kubectl port-forward`**

Every alternative was checked against the live tenant, not reasoned about.

| Option | Verdict | Evidence |
|---|---|---|
| `type: LoadBalancer` (classless) | **stays `<pending>` forever** | `kubectl … get ciliumloadbalancerippool` → *No resources found*; `kubectl … get ciliuml2announcementpolicy` → *No resources found*. `11-tenant-cilium.yaml` sets only `ipam.mode: kubernetes` — no LB-IPAM pool is configured on arrakis at all. (contraxia's `lan-pool` is a different cluster.) |
| chisel-classed LB | **rejected on principle** | Publishes on a public DigitalOcean droplet. Brief forbids it for SSH, and it is the right call: sshd + an unpaired Orca port on the open internet is not worth this box. Also the droplet is currently dead. |
| `NodePort` / `hostPort` | **not reachable from the Mac** | Node internal IP is `10.0.2.2` (KubeVirt masquerade private side). The worker's LAN-bridged second NIC reports up but carries **no address**: `kubectl --context admin@contraxia get vmi -n tenants -o custom-columns='NAME:…,IF:.status.interfaces[*].name,IP:.status.interfaces[*].ipAddress'` → `default,br-multus` / `10.244.0.48` — one IP for two interfaces. A NodePort would only be reachable from contraxia's pod network. |
| NetBird mesh (Track G) | **the correct endgame, not today** | In flight in another track. |
| **ClusterIP + port-forward** | **taken** | Needs nothing new, private by construction, rides the path the Mac already uses for kubectl. |

**port-forward through the k0smotron/konnectivity tunnel was proven working**,
which is the load-bearing assumption:

```
$ kubectl … port-forward -n kube-system deploy/coredns 19180:9153 &
$ curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:19180/metrics
200
```

Consequence for Orca: `PAIRING_ADDRESS` is set to `127.0.0.1`. That is not a
fudge — it is the client-advertised address, the bind is always `0.0.0.0:6768`,
and `127.0.0.1` is literally where the Mac reaches this server through a
forward. When the mesh lands, change that one env value to the NetBird name and
restart the pod; nothing else in the manifest moves.

---

## 5. Decision 3 — sizing, and the ceiling

```
$ kubectl … get node arrakis-general-57f89-7b6cj -o jsonpath='{.status.allocatable}'
{"cpu":"4","ephemeral-storage":"47269409509","memory":"8029516Ki","pods":"110"}
```

4 cores / **7.66 GiB for the entire node**, k0s system pods included (kube-proxy,
multus, konnectivity, cilium, coredns, metrics-server, kubevirt-csi-node). That
number comes straight from `machinetemplate-general.yaml`:
`domain.cpu.cores: 4`, `domain.memory.guest: 8Gi`.

Chosen: `requests: {cpu: 1, memory: 2Gi}`, `limits: {memory: 5Gi}`, **no CPU
limit** (a compile burst should eat idle cores, not get CFS-throttled; memory is
the guard rail). 5 GiB leaves ~2 GiB of node headroom so a runaway build evicts
this pod rather than `kube-proxy`.

**The honest comparison.** The MacBook's OrbStack VM is 12 GiB. This box's
ceiling is 5. Against contraxia's own devbox VM (12 vCPU / 32 GiB) it is a
rounding error. Framing: this is the *tenant-side, always-on, small* box —
useful for an agent or two, a shell, a build — not the place to move heavy
workspaces.

**The fix is one field and it is not mine to change.**
`tenants/arrakis/infra/machinetemplate-general.yaml` →
`domain.memory.guest` / `domain.cpu.cores`. Editing it re-rolls every arrakis
worker (the template is immutable; CAPI rolls the MachineDeployment) and eats
hub RAM that `20-cpu-workspace`'s 32 GiB VM has already claimed. contraxia has
room — `kubectl describe node r730` → 8201m cpu (25%) / 35521078Ki memory (36%)
requested of 32 cores / ~94 GiB — but that accounting predates the devbox VM
actually booting. **Coordinator's call, not this track's.** My recommendation if
the user wants real offload on arrakis: bump the general pool to
`cores: 8 / guest: 24Gi` and raise this StatefulSet's limit to `16Gi` in the
same change.

Note the pool is autoscaled 1–5 by `05b-cluster-autoscaler.yaml` — which is
**commented out** of the kustomization ("minimal:"), so today there is exactly
one worker and no autoscaling. A Pending devbox will not summon a second VM.

---

## 6. Decision 4 — persistence, and what survives what

`volumeClaimTemplate` `data` → 100Gi on StorageClass `kubevirt`, mounted at
`/data`. Everything durable lives under it: `$HOME` (`/data/home` — agent OAuth
state, Orca config, git worktrees) and the sshd host key (`/data/ssh-host/`, so
the Mac's `known_hosts` survives a restart instead of screaming MITM).

The `kubevirt` class is a passthrough: `csi.kubevirt.io` with
`infraStorageClassName: fast-block`, `bus: scsi`. So a tenant PVC becomes a
`fast-block` zvol on contraxia (zfs-localpv, ext4-on-zvol, thin,
`volblocksize 16k`) hot-plugged into whichever worker VM the pod lands on.

| Event | `/data` | container root fs |
|---|---|---|
| pod restart | **survives** | wiped — bootstrap re-installs |
| worker VM rebuild / MachineDeployment roll | **survives** (the zvol is on contraxia; kubevirt-csi re-attaches) | wiped |
| `kubectl delete pvc data-devbox-0` | **destroyed** — `fast-block` is `reclaimPolicy: Delete` | — |

That last row is the one destructive command in this design. Note the contrast
with `19-orca-cell`, whose PVC is on `fast-zfs` (`reclaimPolicy: Retain`); the
tenant path deliberately reclaims so tenant deletion frees hub storage.

**The storage blocker from the round-1 briefs is GONE.** The `tank` zpool now
exists:

```
$ kubectl --context admin@contraxia get zfsnode r730 -n openebs -o yaml
pools:
- name: tank
  free: 13790821004Ki      # ~13.7 TiB
  used: 50548Ki
```

`zfs-localpv-node` is `2/2 Running`, `zfs-localpv-controller` `4/4 Running`.
100Gi thin-provisioned reserves nothing and costs what is written.

⚠️ **The block-mode defect the brief warned about is NOT cleared.** On contraxia
the `devbox-root` DataVolume importer crashes in `GetAvailableSpaceBlock`
(Track H is diagnosing). That is CDI's importer on a `volumeMode: Block` PVC —
a *different* code path from kubevirt-csi, which provisions a plain filesystem
PVC and hot-plugs it. So it should not apply here. **I could not prove that:**
creating a test PVC needs `kubectl create`, which the guard denies. See §10.

---

## 7. Runbook — bring it up, then activate Orca

Everything here is manual by design: git cannot create a Secret from a local
key, cannot run `orca account add`'s interactive OAuth, and cannot hold a
pairing code.

### Step 0 — precondition

`kubectl … get nodes` shows the arrakis worker **Ready** and
`kubectl … get sc` shows `kubevirt (default)`. Both true as of 2026-08-26.

### Step 1 — SSH key Secret (before or shortly after first reconcile)

```sh
kubectl --context admin@arrakis --server=https://192.168.2.240:6443 \
  -n workspaces create secret generic devbox-ssh-key \
  --from-file=mershab.pub=$HOME/.ssh/id_ed25519.pub
```

The mount is `optional: true`, so unlike `20-cpu-workspace`'s VM this does not
hang the pod Pending — a missing Secret gives you a **working Orca server whose
sshd refuses every login**, and the pod logs
`[devbox] WARNING: no keys under /etc/devbox-ssh`. Add the Secret and delete the
pod to fix. Multiple keys: add more `--from-file=<name>.pub=…`; the bootstrap
concatenates everything in the directory into `authorized_keys`.

The namespace ships in this profile's payload, so either run this after the
first reconcile or `kubectl create ns workspaces` first.

### Step 2 — watch it come up

```sh
kubectl --context admin@arrakis --server=https://192.168.2.240:6443 \
  -n workspaces logs -f devbox-0
```

Expect the `[devbox]` progress lines. **Allow ~10 minutes** on a cold start —
that is the apt+npm install, not a hang. The `startupProbe` budget matches.

### Step 3 — open the tunnel (leave it running)

```sh
kubectl --context admin@arrakis --server=https://192.168.2.240:6443 \
  -n workspaces port-forward svc/devbox 2222:22 6768:6768
```

### Step 4 — SSH

```sh
ssh -p 2222 dev@127.0.0.1
```

`dev` is uid 1000 with passwordless sudo, `$HOME=/data/home`, `bash`. Pubkey
only — `PasswordAuthentication=no`, `PermitRootLogin=no`, `AllowUsers=dev`,
passed as `sshd -o` flags so no distro default can override them.

### Step 5 — Orca accounts (repeat on every fresh PVC)

```sh
kubectl --context admin@arrakis --server=https://192.168.2.240:6443 \
  -n workspaces exec -it devbox-0 -- setpriv --reuid=1000 --regid=1000 --init-groups \
  env HOME=/data/home orca-ide account add            # claude

kubectl --context admin@arrakis --server=https://192.168.2.240:6443 \
  -n workspaces exec -it devbox-0 -- setpriv --reuid=1000 --regid=1000 --init-groups \
  env HOME=/data/home orca-ide account add --agent codex
```

The `setpriv … HOME=/data/home` wrapper matters: `kubectl exec` lands you as
uid 0 with `HOME=/root`, and credentials written there die with the pod. Same
shape as devex `runbook-shamu.md` §8, adjusted because that image's default user
was already uid 1000 and this container's is not.

> **Keychain / de-auth hazard, carried from round 1:** the user prefers plain
> `claude /login` over any flow that re-issues a token and de-authorises the
> Mac's session. If `orca account add` offers a choice, take the one that leaves
> the Mac alone. Claude Code's own credentials on the Mac are a macOS keychain
> item, not a file — nothing here should touch them.

### Step 6 — pair the Mac

Grab the pairing code from the logs, then on the Mac (tunnel from step 3 still
up):

```sh
kubectl … -n workspaces logs devbox-0 | grep -i 'orca://pair'
orca environment add --name arrakis --pairing-code 'orca://pair?code=…'
```

Or Settings → Remote Orca Servers. The address it will use is `127.0.0.1:6768`
— that is `PAIRING_ADDRESS`, and it is correct only while the port-forward is
open. Mobile pairing: restart the pod once with `ORCA_MOBILE_PAIRING=1` and scan
the QR from the logs (the env var is not wired in this manifest; add it to the
`env:` block if you want it).

### Step 7 — acceptance

```sh
kubectl … -n workspaces get pod devbox-0            # 1/1 Running
kubectl … -n workspaces get pvc                     # data-devbox-0 Bound
ssh -p 2222 dev@127.0.0.1 'id; nproc; free -g; ls -la /data'
ssh -p 2222 dev@127.0.0.1 'claude --version; codex --version; orca-ide --version'
orca status --json                                  # on the Mac, after pairing
```

---

## 8. Gitea token rollover

Written, not run: **`docs/runbooks/gitea-token-rollover.md`**.

The user asked to "orchestrate a gitea token rollover once it's up on arrakis".
Two corrections baked into the runbook: the new forge lands on **contraxia**
(`21-forge.yaml`, `persona: infra`), not arrakis; and "up" now means *reachable
with an admin*, which is half true — verified 2026-08-26:

```
$ curl -s -o /dev/null -w '%{http_code}\n' http://192.168.2.244:3000/
200
$ kubectl --context admin@contraxia -n gitea get pods
gitea-58dc87c87c-9h57h   1/1 Running
gitea-pg-1               1/1 Running
gitea-pg-2               1/1 Running
$ kubectl --context admin@contraxia -n gitea exec deploy/gitea -- gitea admin user list
ID   Username Email IsActive IsAdmin 2FA      # <- header only. ZERO users.
```

So the forge is serving and has no admin, exactly as `21-forge.yaml`'s header
predicted. The runbook's step 1 is therefore correct rather than a duplicate.

**What the rollover surface actually is** — I inventoried it on this Mac rather
than assuming, and it is bigger than the brief's four items. The old OrbStack
Gitea token lives in **five** places:

1. `.git/config` remote `gitea` → `http://mershab:<token>@localhost:3000/…`
   (plaintext in the URL — this is the defect Track I owns)
2. `~/.claude.json` → `mcpServers.gitea.env.GITEA_ACCESS_TOKEN`, with
   `GITEA_HOST=http://localhost:3000`
3. the `tea` CLI login `localgitea`
   (`~/Library/Application Support/tea/config.yml`, currently DEFAULT)
4. the macOS keychain — `git config credential.helper` is `osxkeychain` globally,
   and an internet-password exists for `localhost:3000` / account `mershab`
5. `~/.config/gitea/credentials` (mode 0600, 152 bytes) — **not read**, rewritten
   blind by the runbook

Miss any one and something breaks quietly after the revoke. **No token value
appears in the runbook or in this report.**

---

## 9. Incident found and cleared during this track

**Cilium had been wiped from arrakis and Sveltos would not put it back.** The
arrakis etcd was re-seeded during the storage migration, which destroyed the
Helm release records; Sveltos's cached hash still said `Provisioned`, so it
never reinstalled. Evidence at the time:

```
$ kubectl … -n kube-system get secret -l owner=helm     → No resources found
$ kubectl … get node … -o jsonpath='{…conditions…}'
  Ready=False  container runtime network not ready: … cni plugin not initialized
$ kubectl --context admin@contraxia get clustersummary tenant-cilium-capi-arrakis -n tenants -o jsonpath='{.status}'
  featureID Helm, status Provisioned, lastAppliedTime 2026-07-27T02:13:33Z
  helmReleaseSummaries: cilium → status Managing
```

`policyRef`-delivered profiles *had* re-applied to the fresh cluster (multus DS
Running, the `kubevirt` StorageClass at `resourceVersion 535`), so the failure
was specific to the Helm feature. Nothing could schedule on arrakis — this
blocked Dex, the arrakis edge, both vclusters, and this track.

Escalated; the **coordinator fixed it** with a values hash-nudge to
`11-tenant-cilium.yaml` (commit `9f896ba`). Cilium reinstalled and the node came
Ready inside two minutes. Recorded here because it will happen again the next
time a tenant's etcd is re-seeded, and the tell is
`helmReleaseSummaries: Managing` with a `lastAppliedTime` older than the cluster.

---

## 10. UNVERIFIED

Honest list. Nothing here is a guess presented as fact.

1. **Nothing from this track has been applied.** No pod has ever run. Every
   claim about runtime behaviour is design intent plus the static/container
   checks in §1.
2. **The container was proven on Docker/amd64, not on the arrakis node.** Runs
   1–4 (§3) cover install, sshd, login, and `orca serve` — but under OrbStack's
   runc + seccomp on this Mac, not under k0s + containerd on an Ubuntu 24.04
   KubeVirt guest. The sandbox behaviour in particular is runtime-dependent;
   `ORCA_NO_SANDBOX=1` is set precisely so it does not matter which way the
   node's `apparmor_restrict_unprivileged_userns` falls, but that assumption is
   untested there. Also untested: `enableServiceLinks`, the `startupProbe`
   budget against real tenant network throughput, and how long a cold apt takes
   over vxlan.
3. **The PVC path is unproven.** `kubectl create` is denied, so I could not bind
   a test PVC on the `kubevirt` class. **One command clears this** and I
   recommend the coordinator run it:
   `kubectl --context admin@arrakis --server=https://192.168.2.240:6443 -n default create -f -` with a
   1Gi PVC on `storageClassName: kubevirt`, then check it reaches `Bound`. If it
   does not, the block-mode defect in §6 applies to the tenant path too and this
   track is blocked behind Track H.
4. **Pairing over a port-forward is unproven *end to end*.** The two halves are
   each proven — `port-forward` works through konnectivity (§4, HTTP 200), and
   the server emits a pairing code whose embedded endpoint is
   `ws://127.0.0.1:6768` (§3 run 4) — but no Mac has actually consumed that code
   against a pod. If `orca environment add` refuses a loopback endpoint for a
   *remote* environment, the fallback is an SSH `-L 6768:localhost:6768` tunnel
   through step 4's sshd, or Track G's mesh.
5. **No schema validation.** `kubeconform`/`kubeval` are not installed.
6. **No arrakis `SveltosCluster` exists** — delivery goes through the CAPI
   `Cluster` object's labels. That is how the existing arrakis profiles work, so
   it is almost certainly right, but I did not watch a ClusterSummary appear for
   profile 32 (nothing is pushed to `main` yet).
7. **`~/.config/gitea/credentials` content is unknown** — deliberately not read.
   The runbook overwrites it blind and tells the operator to check for
   collateral.

---

## 11. Recommendations for the coordinator

1. **Run the PVC probe** in §10.3 before merging. It is the one cheap command
   that turns the biggest UNVERIFIED into a fact.
2. **Decide the worker-VM sizing question** (§5). As shipped, this box cannot
   take heavy workspaces off the Mac. Either bump
   `machinetemplate-general.yaml` or set expectations that contraxia's devbox is
   the heavy one.
3. **Do not merge this expecting instant gratification** — first pod start is
   ~10 minutes of apt. That is the documented cost of not needing a private
   registry.
4. **Sequence the gitea runbook after Track F and Track I**, and re-read its
   endpoint caveat: if `git.mershab.com` has landed, every command needs the
   hostname substituted.
5. **Tell whoever owns `19-orca-cell.yaml` that its `ORCA_NO_SANDBOX` remedy is
   broken** (§3 run 3). Once its image blocker clears, that pod will very likely
   hit the same Chromium zygote crash, and the documented fix — flipping
   `ORCA_NO_SANDBOX` to `"1"` — makes it worse, because devex's `entrypoint.sh`
   turns that into a `--no-sandbox` argv element Orca's CLI rejects outright.
   The one-line fix is in `images/orca/entrypoint.sh`: export
   `ELECTRON_DISABLE_SANDBOX=1` instead of appending `--no-sandbox`. That is a
   devex change, and I did not make it — this repo does not own that image.

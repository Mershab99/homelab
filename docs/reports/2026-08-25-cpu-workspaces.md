# CPU workspaces on contraxia — Track B

Date: 2026-08-25
Branch: `feat/cpu-workspaces-contraxia`
Author: dispatched worker (Track B)

**Decision: a KubeVirt VM (`devbox`, Ubuntu 24.04) on the R730, SSH at
`192.168.2.241`.** Manifests are written, schema-validated offline, and
committed. Nothing has been applied to the cluster — Sveltos does that after
the coordinator pushes to `origin/main`, and the profile is gated behind the
in-flight ZFS storage migration.

---

## 1. Options evaluated

| # | Option | Verdict | Why |
|---|--------|---------|-----|
| 1 | **KubeVirt VM + SSH** | **CHOSEN** | Own kernel, systemd, Docker without host-privileged escapes. KubeVirt v1.8.4 and CDI are both `Deployed` on contraxia *today*, and there is a live VM in `tenants` proving the path on this exact node. Persistent disks, deterministic LAN IP. |
| 2 | Privileged pod / StatefulSet with sshd | rejected | Faster to boot, but buys nothing on time-to-first-SSH: it needs the *same* `fast-zfs` PVC and therefore waits on the *same* storage migration. What it costs is real — shared Talos kernel, Docker only via a privileged escape or DinD, no reboot, no kernel modules. The user asked for a machine, not a shell. |
| 3 | Coder | rejected | Two independent reasons. (a) `platform/sveltos/clusterprofiles/15-app-coder.yaml` exists but is **commented out of `kustomization.yaml`** and selects `persona: platform` — that is *arrakis*, a k0smotron tenant with no hypervisor, not contraxia. Re-targeting it is not a small edit. (b) Its `dependsOn` chain is `tenant-ingress` + `auth-stack` (Dex OIDC client, secret to mint) + `db-operators` (a CNPG Postgres), and its own header still carries a `── FILL ──` block ("verify the exact coder chart version… before apply"). That is three subsystems, an OIDC round trip, and an unfinished pin standing between the user and a shell prompt. |

### On devex decision #11 (which rejected Coder for shamu)

Decision #11's reasoning was *"The hardware does not afford KubeVirt"* and *"a
single durable pet pod gains nothing from Coder's fleet mechanics."* The first
premise is **no longer true on contraxia** — this box runs KubeVirt and has ~28
idle cores, so the VM tier that shamu could not afford is available here. The
second premise **still holds**, and it is the one that decides this: we are
provisioning one pet workspace for one human. #11 named the revisit trigger as
*"second human, Windows/GPU workspace templates"* — none of those is present.
So: decision #11's *conclusion* survives (no Coder), its *rationale* is
partially superseded (KubeVirt is on the table now, and I took it).

If a second human or a GPU workspace template appears, revisit — `15-app-coder.yaml`
is still in the tree, and this VM does not block it.

---

## 2. What was delivered

```
platform/sveltos/clusterprofiles/20-cpu-workspace.yaml   # new profile
platform/sveltos/clusterprofiles/kustomization.yaml      # + one line
platform/sveltos/manifests/cpu-workspace/namespace.yaml
platform/sveltos/manifests/cpu-workspace/home-datavolume.yaml
platform/sveltos/manifests/cpu-workspace/virtualmachine.yaml
platform/sveltos/manifests/cpu-workspace/service.yaml
```

House pattern followed: numbered `ClusterProfile` with a `GitRepository`
policyRef pointing at a payload dir of plain manifests — the same shape as
`04-storage.yaml` → `manifests/storage/` (which likewise ships no
`kustomization.yaml` in the payload dir; Sveltos reads the directory).

**Profile number `20-` is claimed by this track.** `18-` was the previous
highest on `main`, and at check time none of the sibling branches
(`orca-cell-contraxia`, `feat/shamu-platform-contraxia`, `migration-watch`) had
added a clusterprofile yet — `git ls-tree` on each still ended at
`18-mershab-apps.yaml`. If Track A also picks `20-`, this one moves; it is a
filename, not a reference.

**Selector is `persona: infra`.** Verified, not assumed:
`kubectl get sveltoscluster -A --show-labels` returns `mgmt/mgmt` with
`persona=infra,sveltos.projectsveltos.io/type=mgmt` — that is contraxia
self-managing. The only other SveltosCluster is `projectsveltos/ai`
(`persona=ai`). There is no `persona=platform` cluster registered right now.

---

## 3. Connect instructions

### Step 1 — put your public key in the cluster (one time)

The manifests reference a Secret that is **not** in git. Create it:

```bash
kubectl --context admin@contraxia --request-timeout=60s create ns workspaces   # if the profile has not reconciled yet
kubectl --context admin@contraxia --request-timeout=60s -n workspaces \
  create secret generic devbox-ssh-key \
  --from-file=mershab.pub="$HOME/.ssh/id_ed25519.pub"
```

The key name inside the Secret does not matter — KubeVirt injects **every** key
in the Secret. Add a second `--from-file=` for a second machine.

> Do this **before** the profile reconciles. virt-launcher mounts the Secret as
> a volume; if it is missing the pod sits `Pending` on the mount rather than
> booting without keys. That failure is loud and safe, but it is avoidable.

I did not read, generate, or commit any key material. The path above is a
placeholder for whichever public key the user actually wants.

### Step 2 — SSH

```bash
ssh ubuntu@192.168.2.241
```

That is the whole thing. `ubuntu` is the Ubuntu cloud image's default user; it
has passwordless sudo. Password auth and root login are both disabled
(`ssh_pwauth: false`, `disable_root: true`).

Optional convenience — `~/.ssh/config` on the MacBook:

```
Host devbox
  HostName 192.168.2.241
  User ubuntu
  ForwardAgent yes
```
…then `ssh devbox`.

No DNS record was created. `external-dns` is running on contraxia but the
in-home split-horizon resolver serves a different subnet than `192.168.2.0/24`,
and guessing at that plumbing is how a "just SSH in" task turns into a DNS
project. An IP is a valid host.

### Watching the first boot

The cloud image import + `apt` run takes a few minutes. Order of appearance:

```bash
kubectl --context admin@contraxia -n workspaces get dv          # devbox-root Importing -> Succeeded
kubectl --context admin@contraxia -n workspaces get vmi         # devbox Scheduling -> Running
kubectl --context admin@contraxia -n workspaces get svc devbox-ssh   # EXTERNAL-IP 192.168.2.241
virtctl --context admin@contraxia -n workspaces console devbox  # serial console if SSH does not come up
```

---

## 4. Sizing, and why

Measured on the node, not estimated:

- `kubectl get node r730 -o jsonpath='{.status.allocatable}'` → `cpu: 31950m`,
  `memory: 98223064Ki` (~93.7 GiB).
- `kubectl top node r730` → `1565m` (4%), `14508Mi` (15%) at the time of writing.

| Knob | Value | Reasoning |
|------|-------|-----------|
| Guest vCPU | **12** (1 socket × 12 cores) | Comfortably parallel builds; still under half the box. |
| CPU *request* | **6** | Deliberate 2:1 overcommit. A dev box is idle between commands; reserving 12 cores for a mostly-idle VM would starve the tracks that come after. |
| Guest memory | **32 GiB** | The stated problem is a MacBook with a 12 GiB OrbStack cap. 32 GiB is unambiguously better and is the single largest lever here. |
| Memory *request* | 32 GiB + KubeVirt overhead (**not** overcommitted) | Set implicitly by `domain.memory.guest`. Memory overcommit on a dev box means the OOM killer arrives during a build. |
| Root disk | **64 GiB**, `fast-block` | Enough for OS + Docker images. Disposable. |
| Home disk | **250 GiB**, `fast-zfs`, thin-provisioned | Costs only what is used; the tank pool is 7×2 mirrors of 2 TB. |

**Headroom left for Tracks A and C: ~60 GiB RAM and ~26 cores of request.**
(93.7 GiB total − ~14.5 GiB in use − ~33 GiB for this VM.)

### IP claim

**`192.168.2.241`** from `lan-pool`, pinned with
`lbipam.cilium.io/ips: "192.168.2.241"`.

Verified against the live cluster:

- `CiliumLoadBalancerIPPool/lan-pool` = `192.168.2.240`–`.250`, `disabled: false`,
  status `IPsAvailable: 10`, `IPsUsed: 1`, no `serviceSelector` (any Service may draw).
- `.240` is `tenants/kmc-arrakis-lb` — confirmed by
  `kubectl get svc -A --field-selector spec.type=LoadBalancer`.
- `CiliumL2AnnouncementPolicy/lan-l2` has `loadBalancerIPs: true` and **no**
  node/service selector, so it already ARPs for every LB IP on this node.
  Nothing extra is needed to make `.241` reachable on the LAN.
- Cilium is `v1.19.5`, which supports the modern `lbipam.cilium.io/ips`
  annotation. (The existing arrakis Service uses the older
  `io.cilium/lb-ipam-ips` key; both are honoured, I used the current one.)

`docs/reports/` did not exist before this commit, so there were no sibling
reports to reconcile IP claims against. **Tracks A and C: take `.242` and up.**

### Why LoadBalancer and not `br0`/Multus

The brief offered a bridge onto `br0` as the reachability path, and it works —
`tenants/arrakis/infra/nad-br-multus.yaml` has been in service for 30 days. I
did not use it. A bridged NIC gets its address from the Bell Hub's DHCP scope,
which means (a) the address can change and (b) pinning it statically requires
knowing a DHCP scope nobody has written down. LB-IPAM gives a fixed address by
declaration, with L2 announcement already configured. Fewer unknowns.

The trade-off, stated plainly: the VM's own NIC is masquerade/pod-network, so
the VM is **not** an L2 peer on the LAN. It can reach the LAN outbound; inbound
is only what the Service exposes (port 22). If this box ever needs mDNS, to run
a DHCP/PXE server, or to be pinged by IP from the LAN, switch to the
`br-multus` NAD — the pattern is in the repo and the comment in
`virtualmachine.yaml` points at it.

---

## 5. What survives, exactly

| Thing | Survives guest `reboot` | Survives VM delete/recreate | Survives node reboot |
|-------|:---:|:---:|:---:|
| `/home` (incl. `/home/ubuntu`, repos, dotfiles, agent state) | yes | **yes** | yes |
| `/` — installed packages, `/etc`, `/var/lib/docker` (images, containers, volumes) | yes | **no** | yes |
| Running processes, tmux sessions | no | no | no |
| The `192.168.2.241` address | yes | yes | yes |

`/home` is a **standalone** `DataVolume` (`devbox-home`), not a
`dataVolumeTemplate`. A `dataVolumeTemplate` is garbage-collected with its
VirtualMachine; this one is not, so `kubectl delete vm devbox` — or a Sveltos
prune of `virtualmachine.yaml` — leaves the user's work alone. It sits on
`fast-zfs`, whose reclaim policy is `Retain`, so even deleting the PVC leaves
the data on the pool.

`/` is a `dataVolumeTemplate` on `fast-block` (`Delete` reclaim). This is the
intended asymmetry: **bump the image URL, delete the VM, get a fresh OS with
your home directory intact.** The cost is that anything installed by hand
outside `/home` is lost on rebuild — which is why the toolchain is declared in
cloud-init rather than installed by hand.

**Not persisted, and worth saying out loud:** Docker images and volumes live on
`/` and are lost on a VM rebuild. If something in Docker matters, bind-mount it
from `/home`.

### Toolchain

Declared in `cloudInitNoCloud.userData`, inline in git, so it is rebuildable
rather than a hand-mutated pet: `git`, `curl`, `jq`, `unzip`, `tmux`, `zsh`,
`build-essential`, `python3-pip`, `python3-venv`, `ripgrep`, `fd-find`,
`docker.io`, `docker-compose-v2`, `qemu-guest-agent`. `ubuntu` is added to the
`docker` group. Language runtimes beyond Python are deliberately absent —
`mise`/`nvm`/`rustup` in `/home` version better than an apt package and survive
a root rebuild. To change the base toolchain: edit the `packages:` list, delete
the VM, let it rebuild.

---

## 6. Validation performed

`kubectl apply --dry-run=client` is blocked by `.claude/hooks/guard-destructive.py`
(the hook matches on `kubectl apply` regardless of `--dry-run`). I did not work
around it. Instead I validated structurally against the **live CRD
`openAPIV3Schema`s pulled read-only from contraxia**, which is strictly stronger
than a client-side dry run:

```
OK    home-datavolume.yaml: DataVolume/devbox-home validates against datavolumes.cdi.kubevirt.io v1beta1
SKIP  namespace.yaml: Namespace is a core type, no CRD schema
SKIP  service.yaml: Service is a core type, no CRD schema
OK    virtualmachine.yaml: VirtualMachine/devbox validates against virtualmachines.kubevirt.io v1
OK    virtualmachine.yaml: cloud-init parses; /dev/disk/by-id/virtio-HOME -> /home, ssh_pwauth off
OK    devbox-ssh: LB IP 192.168.2.241, selector {'vm.kubevirt.io/name': 'devbox'}
OK    storage classes ['fast-block', 'fast-zfs'] — no longhorn
OK    20-cpu-workspace.yaml: ClusterProfile/cpu-workspace validates against clusterprofiles.config.projectsveltos.io v1beta1
```

Also run:

- `kubectl kustomize platform/sveltos/clusterprofiles/` → exit 0, 23
  ClusterProfiles rendered, `cpu-workspace` among them.
- The nested cloud-init YAML-inside-a-YAML-string was parsed and asserted
  separately — it is the one place a mistake is invisible to every schema above.
  Asserted: `#cloud-config` header present, `fs_setup` device matches a declared
  disk `serial`, `mounts` targets `/home`, `ssh_pwauth` is false.
- The `.241` claim and the storage-class set are asserted on parsed *values*,
  not on grep — the comments legitimately mention `.240` and `longhorn`.

The validator script lives in the session scratchpad, not the repo. It is a
one-shot check of four static manifests, not something worth maintaining.

`yamllint`, `kubeconform`, and `kubeval` are not installed on this machine.

---

## 7. UNVERIFIED — read this before trusting section 3

Nothing here has been run against the cluster. Honest list, worst first:

1. **The VM has never booted.** Schema-valid is not the same as accepted by
   KubeVirt's *validating webhook*, and neither is the same as working. Every
   runtime claim in this report is a design intention.
2. **Blocked on the ZFS migration.** At the time of writing
   `kubectl get sc` returns only `longhorn (default)` and `longhorn-static`;
   `fast-zfs`/`fast-block` **do not exist yet**, and the node still shows
   `extensions.talos.dev/{intel-ucode,iscsi-tools,util-linux-tools}` with no zfs
   extension. The profile's `dependsOn: [storage, virt-host]` keeps it inert
   until that lands. This is correct ordering, not a defect — do **not** repoint
   the disks at `longhorn` to make it start sooner.
3. **`fast-zfs` has no CDI StorageProfile.** `zfs.csi.openebs.io` is not one of
   CDI's known provisioners, so the auto-generated profile is likely to come up
   with empty `claimPropertySets`. I worked around it by spelling out
   `accessModes` + `volumeMode` on both DataVolumes, which short-circuits the
   lookup. **If a blank `fast-zfs` DataVolume still wedges in
   `PendingPopulation`, the fix is a `StorageProfile` for `fast-zfs` alongside
   the existing `fast-block` one in
   `clusters/baremetal/addons/kubevirt-hco/storageprofile.yaml`** — that file is
   Track/issue territory for storage, so I did not edit it. Flagging it as a
   likely follow-up.
4. **SSH key propagation.** `accessCredentials` with `propagationMethod: noCloud`
   is documented to merge the Secret's keys into the cloud-init userdata as
   `ssh_authorized_keys`, landing them on the image's **default** user
   (`ubuntu`). I have not observed this on KubeVirt v1.8.4. If keys do not
   appear, the serial console (`virtctl console devbox`) is the way in, and the
   fallback is putting the public key directly in the inline `userData` — an SSH
   *public* key is not secret and would be fine in git; the brief asked for the
   Secret shape, so that is what I built.
5. **Disk enumeration.** `/home` is located by disk `serial: HOME` →
   `/dev/disk/by-id/virtio-HOME` rather than by `/dev/vdb`, so it does not
   depend on enumeration order. That the udev path materialises under this
   guest kernel is documented KubeVirt behaviour, not something I observed.
6. **cloud-init module ordering.** The design depends on `cc_disk_setup` and
   `cc_mounts` running *before* `cc_users_groups`, so `/home` is mounted before
   `/home/ubuntu` is created on it. That is Ubuntu's stock `cloud.cfg` ordering.
   Not observed on this image.
7. **LoadBalancer → masquerade VM.** Service → virt-launcher podIP:22 →
   masquerade NAT → guest:22 is the standard `virtctl expose` flow. Not observed
   here. The Service selector `vm.kubevirt.io/name` **was** verified against the
   live arrakis virt-launcher pod's labels.
8. **First boot needs egress** for the cloud image import (CDI, from
   `cloud-images.ubuntu.com`) and for `apt`. The arrakis VM does the same on this
   node, so this is very likely fine — but it is inference, not a test.

**Recommended first-run order:** create the Secret → let the storage migration
finish → merge → watch `get dv` then `get vmi` → `ssh ubuntu@192.168.2.241`.

---

## 8. Deliberate non-goals

- No DNS record (see §3).
- No `br0`/Multus attachment (see §4).
- No second workspace. A second one is a copy of `virtualmachine.yaml` +
  `service.yaml` with a new name and the next IP; the namespace comment says so.
  Templating that for a fleet of one is exactly what devex decision #11 warned
  against.
- No backup wiring. `04b-backup.yaml` (Velero → B2) is still commented out of
  `kustomization.yaml` cluster-wide; `/home` on `fast-zfs` gets `Retain` plus
  `zfs snapshot`, which is what is available today.

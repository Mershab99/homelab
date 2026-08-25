# Next steps

Deliberate deferrals, roughly ordered. Each item says what unblocks it.

## Storage refit (in flight — Longhorn is still the live layer)

Git already describes ZFS everywhere; **the metal does not yet**. Verified on
the hub 2026-08-25: `longhorn` is still the default StorageClass,
`longhorn-system` is Active with 3 bound volumes (`monitoring/minio-data` 50Gi,
`tenants/etcd-data-kmc-arrakis-etcd-0` 4Gi, one 5428Mi tenant PVC), and the node
runs schematic `36cd6536…` = intel-ucode 20260512 + **iscsi-tools v0.2.0** +
util-linux-tools 2.41.4 — **no zfs extension**. Everything in `docs/` other than
this section describes the post-refit state.

Ordering is fixed — do not reorder, and do not try to run both layers at once:

1. **Tear down Longhorn first**, accepting the loss of those 3 volumes
   (`docs/runbooks/migrating-longhorn-to-zfs.md` is the only procedure).
2. **Then** upgrade the node straight to the zfs schematic already pinned in
   `bootstrap/talos/controlplane.yaml`
   (`c86a996e871ad7d755f8f99109cbb0fda2b2903ba4c1b76668b257e9a2030eea:v1.13.5`).
   A transitional iscsi+zfs schematic exists as an escape hatch but was
   **rejected** — the point of the teardown-first order is to never need it.
3. **Then** `./bootstrap/zfs/create-pool.sh`, then let Sveltos reconcile
   `04-storage.yaml`.

`controlplane.yaml` is deliberately *ahead* of the metal here; that drift closes
at step 2, not before. This cycle also strips the `intel_iommu=on` / pcirebind /
vfio kernel args so the upgrade changes only the extension set plus the ZFS ARC
cap (`zfs.zfs_arc_max=21474836480`, 20 GiB) — GPU passthrough comes back as its
own later upgrade.

## Topology rebuild (the big one)

Planned shape: a small **OptiPlex management cluster** takes over the hub role
(Sveltos, Flux, CAPI, hosted control planes, alerting); the **R730 becomes a
pure workload node**. R820 (spinning disks) joins later as the bulk/cold tier.

- Move Sveltos/Flux/CAPI + the k0smotron hosted CPs to the OptiPlex. The
  KubevirtCluster `infraClusterSecretRef` seam is already noted in
  `tenants/arrakis/infra/cluster.yaml` for the mgmt/infra split.
- Alerting must live on the mgmt cluster, not the workload cluster — a
  workload-cluster outage must not blind storage alerts.
- R820: **separate** ZFS pool (RAIDZ2 fits the HDD/bulk workload). Do NOT merge
  tiers into tank. Media/backup targets/cold data move there.
- Replicated storage only when there are 2+ workload nodes, and only for
  workloads that are single-instance AND must float. App-level replication
  (Postgres streaming, etcd) stays on LocalPV-ZFS — replicated blocks under a
  replicating app pays for durability twice. Two nodes is not a quorum; the
  OptiPlex can arbitrate (Mayastor/Ceph mon) without holding data.
- k0smotron CP replicas 1 → 3 when the second node lands (`cluster.yaml`).

## Storage follow-ups (unblocked by re-enabling observability)

The 07-observability profiles are commented out in
`platform/sveltos/clusterprofiles/kustomization.yaml`. When they return:

- `zfs_exporter` + alerts: pool state != ONLINE, any vdev read/write/checksum
  errors, capacity > 75% (~10.5TB), fragmentation trend, ARC hit-rate collapse,
  `usedbysnapshots` growth per dataset, SMART wear/reallocated sectors.
- Scheduled scrub CronJob (monthly) — replaces the manual scrub in the
  migration runbook.
- snapscheduler (or a Sveltos-delivered CronJob) for tiered local snapshots:
  hourly×24 / daily×14 / weekly×8. Watch forgotten snapshots pinning space.

## Storage follow-ups (anytime)

- Quarterly restore drill: Velero restore of a real PVC into a scratch ns,
  app starts against it. Calendar it.
- `zfs send | recv` for datasets where kopia is too slow (media) — pairs with
  the R820 when it exists; until then B2 via Velero is the only off-box copy.
- Revisit `17-family-apps.yaml` size caps (mediaserver 1536Gi, photoprism
  1024Gi) — Longhorn-era limits; tank is ~14TB thin-provisioned.
- Raise the `tenants-storage` ResourceQuota (2Ti) when tenant usage warrants.

## Hygiene / debt

- **`bootstrap/talos/controlplane.yaml` carries live PKI in plaintext in git**
  (machine.ca.key, machine.token, cluster.secret, etcd CA, SA key,
  secretboxEncryptionSecret). Remediate: split secrets out (SOPS bundle like
  the parked `.taskfiles/bootstrap.yml` flow) or accept + rotate on any leak.
  Flagged 2026-08-24.
- `.taskfiles/talos.yml` + `.github/workflows/talos-images.yaml` reference
  nonexistent `bootstrap/talos/{hub,infra}/…` paths and Talos v1.9.1 — rewrite
  against `r730-schematic.yaml`/`controlplane.yaml` or delete.
- `bootstrap/talos/README.md` documents a `task talos:r730:config` flow whose
  input (`r730.yaml`) doesn't exist — reality is the committed rendered
  `controlplane.yaml`; update the README.
- kubevirt-csi node image is `:latest` (TODO already in
  `tenants/arrakis/addons/kubevirt-csi/kubevirt-csi.yaml`) — pin a digest.

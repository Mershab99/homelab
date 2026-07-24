# Vended databases — the convention

Operators (CloudNativePG + MOCO) come from `09-db-operators.yaml`. Individual
databases are declared as CRs **in the consuming app's namespace**; the operator
provisions the DB + a credentials Secret the app mounts. No DB is provisioned by
the operator profile itself.

## Postgres (CloudNativePG)

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pg
  namespace: myapp
spec:
  instances: 3
  storage:
    size: 10Gi
    storageClass: kubevirt        # tenant CSI -> bare-metal Longhorn
  bootstrap:
    initdb:
      database: app
      owner: app
```

- Auto-generated Secret **`pg-app`** (`<cluster>-app`), keys: `username`,
  `password`, `host`, `port`, `dbname`, `uri`, `jdbc-uri`, ... The app references it.
- Services: `pg-rw:5432` (primary RW), `pg-ro` (replicas), `pg-r` (any).

## MySQL (MOCO)

```yaml
apiVersion: moco.cybozu.com/v1beta2
kind: MySQLCluster
metadata:
  name: mydb
  namespace: myapp
spec:
  replicas: 3
  podTemplate:
    spec:
      containers:
        - name: mysqld
          image: ghcr.io/cybozu-go/moco/mysql:8.4.8
  volumeClaimTemplates:
    - metadata:
        name: mysql-data           # MUST be named mysql-data
      spec:
        storageClassName: kubevirt
        accessModes: ["ReadWriteOnce"]
        resources:
          requests: {storage: 10Gi}
```

- Secret **`moco-mydb`** (`moco-<name>`), keys `ADMIN_PASSWORD`,
  `WRITABLE_PASSWORD`, `READONLY_PASSWORD` (fixed users `moco-admin` /
  `moco-writable` / `moco-readonly`).
- Services: `moco-mydb-primary:3306` (RW), `moco-mydb-replica`.

## Publishing a DB PUBLICLY (the internet-facing product)

The tenant Traefik has TCP entrypoints `postgres` (:5432) and `mysql` (:3306)
and matching Gateway TCP listeners (see `tenant-gateway/gateway.yaml`), forwarded
out through node-02/VPS-02 (add `--port` 5432/3306 to the VPS chisel server, or
they ride the existing Traefik LB Service — one ExitNode). To expose ONE cluster,
add a `TCPRoute` (experimental CRD, already shipped in tenant-gateway):

```yaml
apiVersion: gateway.networking.k8s.io/v1alpha2
kind: TCPRoute
metadata: {name: pg-public, namespace: traefik}
spec:
  parentRefs: [{name: shared, namespace: traefik, sectionName: postgres}]
  rules:
    - backendRefs: [{name: pg-rw, namespace: myapp, port: 5432}]   # + a ReferenceGrant in myapp
```

**Security (do NOT skip):** Postgres/MySQL wire protocols have no SNI, so ONE
public port fronts ONE cluster — multiple public DBs need distinct ports. Enforce
TLS (`spec.certificates` on the CNPG Cluster / MOCO TLS), strong roles, and a
NetworkPolicy. Prefer Netbird-only for admin; reserve the public port for a DB
you genuinely intend to vend to the internet.

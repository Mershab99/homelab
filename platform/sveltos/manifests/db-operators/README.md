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
    storageClass: kubevirt        # tenant CSI -> bare-metal LocalPV-ZFS
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

The arrakis edge (12-tenant-ingress) exposes raw TCP via the ingress-nginx
`tcp:` block — the same mechanism as the 6443 API passthrough — riding the one
chisel→DO edge LB Service. To expose ONE cluster, add its port to the
ingress-nginx values in 12-tenant-ingress:

```yaml
tcp:
  "5432": "myapp/pg-rw:5432"
```

**Security (do NOT skip):** Postgres/MySQL wire protocols have no SNI, so ONE
public port fronts ONE cluster — multiple public DBs need distinct ports. Enforce
TLS (`spec.certificates` on the CNPG Cluster / MOCO TLS), strong roles, and a
NetworkPolicy. Prefer LAN-only for admin; reserve the public port for a DB
you genuinely intend to vend to the internet.

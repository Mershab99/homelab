# chisel-operator — ExitNode wiring

The `ingress-external` ClusterProfile installs chisel-operator + reads
this directory via GitRepository policyRef so the ExitNode CR + any
future siblings land on the mgmt cluster.

## Files

- `exit-node.yaml` — the ExitNode CR. Edit the `host`, `port`, and `auth`
  fields once the VPS is provisioned and the chisel token sealed.

## Workflow

1. Provision a VPS with public IPv4. Note the IP.
2. Generate a chisel auth token: `openssl rand -base64 32`.
3. Run chisel-server on the VPS:
   ```bash
   docker run -d --restart=always \
     -p 9090:8080 -p 80:80 -p 443:443 \
     --name chisel-server \
     jpillora/chisel:latest \
     server --reverse --auth "user:<TOKEN>"
   ```
4. Seal the token for the mgmt cluster (see the comment block at the top
   of `exit-node.yaml` for the kubeseal command).
5. Fill `host`, `port`, `auth` in `exit-node.yaml`. Commit. Sveltos
   reconciles, chisel-operator opens the reverse tunnel,
   ingress-nginx-external's Service gets the VPS IP as its EXTERNAL-IP.

## Rotation

Regenerate the token, re-seal, re-run chisel-server with the new value.
The Secret name stays the same so the ExitNode CR doesn't need editing.

# grafana — Dex OAuth2 client secret

Grafana federates to Dex via the `generic_oauth` provider. The client_id is
`grafana` (hardcoded in the Grafana CR); the client_secret is consumed from a
plaintext Secret named `grafana-oidc` in the monitoring ns (key `clientSecret`).

## Generate + apply

1. Generate a random client secret (the SAME string goes into Dex's `grafana`
   staticClient — see `secrets/infrastructure/dex/README.md`):
   ```bash
   openssl rand -base64 32
   ```
2. Put it in `grafana-oidc.secret.yaml` (copy of the `.example.yaml`) AND in
   the `grafana` staticClient of `dex-config.secret.yaml`, then:
   ```bash
   ./secrets/apply.sh
   ```

## Rotation

Re-run with a new value in both files and `./secrets/apply.sh` — same Secret
name, idempotent. Restart Grafana to pick up the new secret.

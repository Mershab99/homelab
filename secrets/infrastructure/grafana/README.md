# grafana — Dex OAuth2 client secret

Grafana federates to Dex via the `generic_oauth` provider. The client_id is
`grafana` (hardcoded in the Grafana CR); the client_secret is consumed via
file mount from a sealed Secret named `grafana-oidc` in the monitoring ns
(key: `clientSecret`).

## Generate + seal

1. Generate a random client secret (same string also goes into Dex's
   `staticClients` list — see `secrets/infrastructure/dex/README.md`):
   ```bash
   GRAFANA_CLIENT_SECRET=$(openssl rand -base64 32)
   ```
2. Seal for the monitoring ns:
   ```bash
   kubectl create secret generic grafana-oidc \
     --namespace=monitoring \
     --from-literal=clientSecret="$GRAFANA_CLIENT_SECRET" \
     --dry-run=client -o yaml \
   | kubeseal \
       --controller-namespace=sealed-secrets \
       --controller-name=sealed-secrets-controller \
       --scope cluster-wide \
       -o yaml \
   > secrets/infrastructure/grafana/grafana-oidc.sealedsecret.yaml
   ```
3. Add the corresponding entry to `dex-config.yaml`:
   ```yaml
   - id: grafana
     secret: <GRAFANA_CLIENT_SECRET>
     redirectURIs:
       - https://grafana.mershab.com/login/generic_oauth
   ```
   Re-seal dex-config per `secrets/infrastructure/dex/README.md`.

Commit both sealed files.

## Rotation

Re-run steps 1–3 with a new value. Both files have the same Secret name so
overwriting is idempotent. Restart Grafana to pick up the new secret.

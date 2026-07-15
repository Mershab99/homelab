# dex secrets

Dex reads its entire runtime config from a Secret named `dex-config` in the
`dex` namespace. Users (email + bcrypt'd password) and per-UI OAuth2 client
secrets all live there. Fill `dex-config.example.yaml` → `dex-config.secret.yaml`
(plaintext + gitignored) and apply with `./secrets/apply.sh`.

## Generate users + clients

1. **bcrypt the admin password** (Dex requires bcrypt for `staticPasswords`).
   The day-1 login is `mershab` / `mershab` — change it later:
   ```bash
   ADMIN_PASSWORD=mershab
   ADMIN_BCRYPT=$(htpasswd -bnBC 10 "" "$ADMIN_PASSWORD" | tr -d ':\n')
   ```
2. **Generate client secrets** (one per OAuth2 client):
   ```bash
   K8S_CLIENT_SECRET=$(openssl rand -base64 32)
   GRAFANA_CLIENT_SECRET=$(openssl rand -base64 32)
   ```
   Note these — they'll also need to land in their respective consumer
   configs (e.g. Grafana's own values reference the `grafana` client
   secret).

3. **Assemble the dex config**. `staticClients` is the per-app OAuth2 client
   registry — one entry per downstream app, each with its own id + secret +
   redirectURIs. Adding a new app later is just another entry plus a sealed
   client-secret Secret on the consumer side.
   ```yaml
   # dex-config.yaml
   config.yaml: |
     issuer: https://auth.mershab.com
     storage:
       type: kubernetes
       config:
         inCluster: true
     web:
       http: 0.0.0.0:5556

     # Auth backends. password-db is the day-1 backend (no upstream IdP).
     # To add an upstream IdP later (GitHub, LLDAP, Google) WITHOUT touching
     # any downstream app, add a connector here. The staticClients list
     # below is unchanged; downstream apps keep talking to Dex.
     #
     # connectors:
     #   - type: github
     #     id: github
     #     name: GitHub
     #     config:
     #       clientID: <gh-oauth-app-client-id>
     #       clientSecret: <gh-oauth-app-client-secret>
     #       redirectURI: https://auth.mershab.com/callback
     enablePasswordDB: true
     staticPasswords:
       - email: mershab@integratrace.com
         hash: "$ADMIN_BCRYPT"
         username: mershab
         userID: 1

     # staticClients — one per downstream app. Each app gets its own
     # client_id, client_secret, and redirect URIs. Federation comes from
     # this list; downstream apps don't know or care what backend Dex used.
     staticClients:
       # Shared by every OIDC-enabled kube-apiserver (tenant Kamaji + every
       # vCluster). Bare-metal apiserver is NOT OIDC-enabled.
       - id: kubernetes
         name: Kubernetes
         secret: "$K8S_CLIENT_SECRET"
         redirectURIs:
           - http://localhost:8000        # kubectl oidc-login local flow
           - http://localhost:18000
       - id: grafana
         name: Grafana
         secret: "$GRAFANA_CLIENT_SECRET"
         redirectURIs:
           - https://grafana.homelab.mershab.com/login/generic_oauth
       # Future apps: one block each.
       # - id: home-assistant
       #   secret: $HA_CLIENT_SECRET
       #   redirectURIs: [https://home.homelab.mershab.com/auth/oauth2_response]
   ```

## Fill + apply

Paste the bcrypt hash and each client secret into the placeholders in
`dex-config.secret.yaml` (copy of `dex-config.example.yaml`), then
`./secrets/apply.sh`. The dex chart's `configSecret.create: false,
configSecret.name: dex-config` directive consumes it.

Each client secret must ALSO match its consumer's own Secret:
- `secrets/infrastructure/grafana/grafana-oidc.secret.yaml` (key `clientSecret`).
- Tenant/vCluster apiservers validating this issuer need only the issuer URL +
  client_id, not the secret.

## Adding an upstream IdP later (no downstream churn)

The `staticClients` list IS the federation surface — every downstream app
binds to a stable client_id, regardless of what backend Dex uses to verify
the user.

To add GitHub OAuth (or LLDAP, or anything Dex supports) later:

1. Uncomment the `connectors:` block in `dex-config.yaml`, fill in the
   upstream credentials.
2. (Optional) Remove `enablePasswordDB: true` if you want to retire the
   password-db backend.
3. Re-seal + commit. Dex picks up the new config.

Downstream apps don't change — their client_id and client_secret continue
to point at Dex; only the *user-facing* login flow changes (password prompt
→ GitHub OAuth redirect).

## Rotate

Re-run the seal command with new secret values. Dex picks up the new Secret
on its next reconcile (no pod restart needed, but a rollout doesn't hurt:
`kubectl -n dex rollout restart deployment/dex`).

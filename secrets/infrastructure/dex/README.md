# dex secrets

Dex reads its entire runtime config from a Secret named `dex-config` in the
`dex` namespace. Users (email + bcrypt'd password) and per-UI OAuth2 client
secrets all live there. The Secret is sealed cluster-wide before commit.

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
   HEADLAMP_CLIENT_SECRET=$(openssl rand -base64 32)
   GRAFANA_CLIENT_SECRET=$(openssl rand -base64 32)
   OAUTH2_PROXY_CLIENT_SECRET=$(openssl rand -base64 32)
   ```
   Note these — they'll also need to land in their respective consumer
   configs (e.g. Headlamp's own Helm values reference `headlamp` client
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
       - id: headlamp
         name: Headlamp
         secret: "$HEADLAMP_CLIENT_SECRET"
         redirectURIs:
           - https://headlamp.homelab.mershab.com/oauth-callback
       - id: grafana
         name: Grafana
         secret: "$GRAFANA_CLIENT_SECRET"
         redirectURIs:
           - https://grafana.homelab.mershab.com/login/generic_oauth
       # oauth2-proxy — the forwardAuth gate for services without native OIDC
       # (longhorn, hubble, traefik dashboard). One client covers all of them.
       - id: oauth2-proxy
         name: oauth2-proxy
         secret: "$OAUTH2_PROXY_CLIENT_SECRET"
         redirectURIs:
           - https://oauth2.homelab.mershab.com/oauth2/callback
       # Future apps: one block each.
       # - id: home-assistant
       #   secret: $HA_CLIENT_SECRET
       #   redirectURIs: [https://home.homelab.mershab.com/auth/oauth2_response]
   ```

## Seal + commit

```bash
kubectl create secret generic dex-config \
  --namespace=dex \
  --from-file=config.yaml=./dex-config.yaml \
  --dry-run=client -o yaml \
| kubeseal \
    --controller-namespace=sealed-secrets \
    --controller-name=sealed-secrets-controller \
    --scope cluster-wide \
    -o yaml \
> secrets/infrastructure/dex/dex-config.sealedsecret.yaml
```

The sealed file gets applied by Flux to the `dex` namespace. The dex chart's
`configSecret.create: false, configSecret.name: dex-config` directive
consumes it.

Same client secret values must also land in the corresponding consumer's
namespace, sealed separately:
- `secrets/infrastructure/headlamp/oidc-client-secret.sealedsecret.yaml`
  (key: `clientSecret`) for the Headlamp Helm values to consume.
- One sealed Secret per future app (grafana, home-assistant, etc.) in that
  app's namespace.
- (Future) any tenant/vCluster apiserver that needs to validate against
  this issuer — they only need the issuer URL + client_id, not the secret.

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

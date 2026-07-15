# cert-manager secrets

cert-manager's `letsencrypt-prod` ClusterIssuer needs a Cloudflare API token
to solve DNS-01 challenges on the `mershab.com` zone. The same token is used
by external-dns, so it goes into two namespaces (cert-manager + external-dns).
Plaintext + gitignored — see `secrets/README.md` for the convention.

## Create the token (Cloudflare dashboard)

1. https://dash.cloudflare.com/profile/api-tokens → Create Token
2. Template: "Edit zone DNS"
3. Permissions: `Zone:DNS:Edit`, `Zone:Zone:Read`
4. Zone Resources: include `mershab.com`
5. Save and copy the token (shown once).

## Fill + apply

Paste the token into both filled copies, then apply:

```bash
cp cloudflare-token.example.yaml cloudflare-token.secret.yaml   # cert-manager ns
cp ../external-dns/cloudflare-token.example.yaml \
   ../external-dns/cloudflare-token.secret.yaml                 # external-dns ns
# replace REPLACE_WITH_CLOUDFLARE_API_TOKEN in both, then:
./secrets/apply.sh
```

## Rotate

Re-run with the new token value and `./secrets/apply.sh` — same Secret name,
idempotent re-apply.

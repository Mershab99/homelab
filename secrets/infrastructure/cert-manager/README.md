# cert-manager secrets

cert-manager's `letsencrypt-prod` ClusterIssuer needs a Cloudflare API token
to solve DNS-01 challenges on the `mershab.com` zone. The token is sealed
**cluster-wide** so the same SealedSecret can also satisfy external-dns
(which expects the Secret in its own namespace).

## Create the token (Cloudflare dashboard)

1. https://dash.cloudflare.com/profile/api-tokens → Create Token
2. Template: "Edit zone DNS"
3. Permissions: `Zone:DNS:Edit`, `Zone:Zone:Read`
4. Zone Resources: include `mershab.com`
5. Save and copy the token (shown once).

## Seal the token (run once, after sealed-secrets is Ready on the mgmt cluster)

```bash
read -rs CF_TOKEN     # paste the token; not echoed
kubectl create secret generic cloudflare-api-token \
  --namespace=cert-manager \
  --from-literal=api-token="$CF_TOKEN" \
  --dry-run=client -o yaml \
| kubeseal \
    --controller-namespace=sealed-secrets \
    --controller-name=sealed-secrets-controller \
    --scope cluster-wide \
    -o yaml \
> secrets/infrastructure/cert-manager/cloudflare-api-token.sealedsecret.yaml
```

The `cluster-wide` scope means the resulting SealedSecret can be applied to
ANY namespace (including `external-dns/`) without re-sealing. Commit the
resulting file to Git.

## Wire into Flux (one-time)

The sealed file gets applied by a tiny Flux Kustomization:

```bash
# secrets-ks.yaml at clusters/baremetal/ — to be added when sealing happens
```

Reconciling that Kustomization makes the SealedSecret land in
`cert-manager/` and `external-dns/` namespaces; the controllers decrypt to
plain Secrets named `cloudflare-api-token`.

## Rotate

When the Cloudflare token is rotated, re-run the seal command. The new
SealedSecret has the same name → idempotent re-apply.

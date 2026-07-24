# netbird — private overlay convention

Self-hosted NetBird server + operator + the tenant routing peer, delivered by
`platform/sveltos/clusterprofiles/08-netbird.yaml`. This is how every PRIVATE
service is reached: not a LAN LoadBalancer, not the public Traefik Gateway — a
NetBird `NetworkResource` on the overlay.

## Publishing a private app (the convention)

The app is a normal `ClusterIP` Service in its own namespace. To expose it on the
overlay, add ONE `NetworkResource` in that namespace pointing at the shared
`homelab` router + the Service:

```yaml
apiVersion: netbird.io/v1alpha1
kind: NetworkResource
metadata:
  name: home-assistant
  namespace: home-assistant
spec:
  networkRouterRef:
    name: homelab            # the shared router (platform/.../netbird/networkrouter.yaml)
    namespace: netbird
  serviceRef:
    name: home-assistant     # a ClusterIP Service in THIS namespace
  groups:
    - name: family           # NetBird access group(s) allowed to reach it
```

Only peers enrolled in the referenced NetBird group(s) can reach it; nothing
answers from the public path or the LAN without enrollment. Access policy is
managed NetBird-side (groups + policies), not via k8s NetworkPolicy.

`NetworkEgress` (fqdn target) is the variant for exposing an OFF-cluster host
through the router; `NetworkResource` (serviceRef) is the in-cluster case.

## Enrolling your own devices

Laptops/phones join with a setup key — see
`secrets/infrastructure/netbird/setup-key.example.yaml`. The routing peer itself
needs no hand-wired setup key: the operator's PAT
(`secrets/infrastructure/netbird/netbird-operator-token.example.yaml`) creates
the network + keys.

## What lands here over the overlay

Home Assistant UI, immich, paperless, DB admin endpoints, and the admin UIs
(Longhorn/Hubble/Grafana on the tenant). mgmt-side Longhorn/Hubble stay
provider-internal (port-forward / `task tunnel`) — no NetBird footprint on mgmt.

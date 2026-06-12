# KubeVirt HCO — installed via OLM

KubeVirt HCO is published as an official OLM operator on operatorhub.io
(`community-kubevirt-hyperconverged`). We install it via OLM
Subscription + OperatorGroup + HyperConverged CR — three small,
hand-authored YAMLs.

## Files

```
clusters/baremetal/addons/kubevirt-hco/
├── README.md
├── operator-group.yaml        # OLM OperatorGroup for kubevirt-hyperconverged ns
├── subscription.yaml          # OLM Subscription pulling the latest community-kubevirt-hyperconverged
└── hyperconverged.yaml        # OUR HyperConverged CR — PCI passthrough + storage
```

Sveltos delivers all three to mgmt via the `virt-host` ClusterProfile's
GitRepository policyRef (see
`platform/sveltos/clusterprofiles/04-virt-host.yaml`).

## Prereq: OLM must be installed first

OLM itself is bootstrapped by the `olm` ClusterProfile at
`platform/sveltos/clusterprofiles/03b-olm.yaml` via the sikalabs
`olm-crds` + `olm` Helm charts. The `virt-host` profile `dependsOn: olm`.

## Upgrade procedure

The Subscription's `channel` field controls upgrade flow. Bump it to a
new channel (e.g. `candidate-v1.20.0`) to roll forward. OLM does the
heavy lifting.

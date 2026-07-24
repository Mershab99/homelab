# AI helpers — kagent + KMCP convention (inside the `ai` vCluster)

Controllers come from `16-ai-helpers.yaml`. Agents and MCP servers are declared
as CRs INSIDE the `ai` vCluster (group `kagent.dev`). Not delivered by the
profile (they need a model API key + would race the CRD install) — apply them
into the vcluster once the controllers are up.

## MCP server (the main use case — KMCP)

KMCP reconciles an `MCPServer` into a Deployment + Service + ConfigMap; stdio
servers get an AgentGateway sidecar (spawns a process per session).

```yaml
apiVersion: kagent.dev/v1alpha1
kind: MCPServer
metadata:
  name: filesystem
  namespace: kmcp-system
spec:
  deployment:
    image: ghcr.io/modelcontextprotocol/servers/filesystem:latest
    port: 3000
    cmd: /usr/local/bin/mcp-server-filesystem
    args: ["/data"]
  transportType: stdio        # stdio | http
  stdioTransport: {}
```

The reconciled Service is how the MCP server is reached in-cluster. Reach it from
outside the vcluster over NetBird (a NetworkResource) if you want it on the overlay.

## Agent (kagent) — optional

```yaml
apiVersion: kagent.dev/v1alpha2
kind: ModelConfig
metadata: {name: default-model, namespace: kagent}
spec:
  provider: Anthropic          # provider sub-fields are provider-specific —
  model: claude-opus-4-8       # VERIFY field names against the modelconfigs CRD
  apiKeySecret: kagent-model-key
  apiKeySecretKey: API_KEY
---
apiVersion: kagent.dev/v1alpha2
kind: Agent
metadata: {name: k8s-helper, namespace: kagent}
spec:
  type: Declarative            # Declarative | BYO
  description: Helps with Kubernetes.
  declarative:
    modelConfig: default-model
    systemMessage: "You are a helpful Kubernetes assistant."
    tools: []
```

The model API key Secret (`kagent-model-key`) is
`secrets/infrastructure/kagent/model-api-key.example.yaml` — apply it INSIDE the
`ai` vcluster (its own kubeconfig), not the tenant.

**Uncertainty:** ModelConfig provider sub-field names were inferred — verify
against the live `modelconfigs.kagent.dev` CRD before applying.

# Phase 1: Dual-Gateway vSR + MaaS Integration POC

## Overview

This document describes the Phase 1 proof-of-concept for integrating the vLLM Semantic Router (vSR) with Red Hat's Models-as-a-Service (MaaS) gateway using a **dual-gateway architecture**.

**Status:** Validated on OpenShift with KServe LLMInferenceService simulator backends.

---

## Why Dual Gateways?

The dual-gateway approach places MaaS and vSR as separate entry points, each owning distinct URL paths:

| Gateway | Path | Responsibility |
|---------|------|----------------|
| MaaS Gateway | `/maas-api/*`, `/<model>/*` | Token minting, per-model RBAC, rate limiting |
| vSR (via MaaS) | `/v1/chat/*` | Semantic routing, model selection |

### Advantages

1. **No ExtProc changes required** - vSR runs as a standalone service behind MaaS, not as an ExtProc filter in the MaaS gateway. This avoids complex filter ordering and keeps vSR deployment independent.

2. **Faster time to validation** - MaaS policies (auth, rate limits) apply at the gateway level. The `/v1/chat/*` HTTPRoute simply forwards authenticated traffic to vSR.

3. **Clean separation of concerns** - MaaS handles identity, tiers, and limits. vSR handles intelligent routing. Neither needs to know the other's internals.

4. **No upstream vSR code changes needed** - The stock vSR container image works as-is. All integration is done via Kubernetes manifests (HTTPRoute, AuthPolicy, ReferenceGrant).

### Tradeoffs

- **Auth is at ingress only** - MaaS authenticates at `/v1/chat/*` ingress. vSR routes directly to model pods, bypassing MaaS per-model RBAC on the inference path.
- **Token rate limits require policy alignment** - TokenRateLimitPolicy predicates must match the auth identity structure for `/v1/chat/*` routes.
- **Duplicate policy management** - If you need identical limits on `/v1/chat/*` and `/<model>/*`, policies must be defined for both paths.

### When to Use Dual-Gateway

- Early demos and POCs
- When vSR must remain a full Envoy gateway (not just ExtProc)
- When you want to validate routing logic before deeper integration
- When upstream vSR changes are not feasible

---

## Architecture

```
                                 +------------------+
                                 |     Client       |
                                 +--------+---------+
                                          |
                                          v
                              +-----------+-----------+
                              |    MaaS Gateway       |
                              |  (openshift-ingress)  |
                              +-----------+-----------+
                                          |
                    +---------------------+---------------------+
                    |                                           |
                    v                                           v
          /maas-api/*, /<model>/*                      /v1/chat/*
                    |                                           |
                    v                                           v
          +------------------+                      +-----------+-----------+
          | MaaS API / Model |                      |   AuthPolicy (token)  |
          | Backends (KServe)|                      +-----------+-----------+
          +------------------+                                  |
                                                                v
                                                    +-----------+-----------+
                                                    |   Semantic Router     |
                                                    |   (vSR + Envoy)       |
                                                    +-----------+-----------+
                                                                |
                                          +---------------------+---------------------+
                                          |                                           |
                                          v                                           v
                                    +-----------+                               +-----------+
                                    |  Model-A  |                               |  Model-B  |
                                    |  (KServe) |                               |  (KServe) |
                                    +-----------+                               +-----------+
```

---

## Traffic Flow

1. **Client requests token** from MaaS API (`POST /maas-api/v1/tokens`)
2. **Client sends inference request** to `POST /v1/chat/completions` with bearer token
3. **MaaS Gateway** receives request at `/v1/chat/*` path
4. **HTTPRoute** forwards to vSR service in `vllm-semantic-router-system` namespace
5. **AuthPolicy** validates token via Kubernetes TokenReview
6. **vSR classifies request** and selects Model-A or Model-B
7. **vSR routes to model pod** directly (via internal service)
8. **Response returns** through vSR and MaaS gateway to client

---

## Installation

### Prerequisites

**Cluster Setup:**
Validated on a Prow cluster. To replicate, stand up a cluster with ClusterBot using:
```
launch 4.20.6 aws,large
```

**Requirements:**
- OpenShift 4.18+ cluster
- `oc` CLI logged in with cluster-admin
- Kuadrant operator installed (provides Authorino + Limitador)
- KServe with LLMInferenceService CRD

### Step 1: Clone Repositories

```bash
# Clone semantic-router (vSR)
git clone https://github.com/nerdalert/semantic-router.git
cd semantic-router
git checkout two-gateway-poc-v1
cd ..

# Clone models-as-a-service (MaaS)
git clone https://github.com/nerdalert/models-as-a-service.git
cd models-as-a-service
git checkout two-gateway-poc-v1
cd ..
```

### Step 2: Deploy MaaS

```bash
cd models-as-a-service/scripts
./deploy-rhoai-stable.sh
cd ../..
```

### Step 3: Deploy Semantic Router

```bash
cd semantic-router/deploy/openshift
./deploy-to-openshift.sh --kserve --simulator --no-public-route
```

Flags:
- `--kserve` - Use KServe LLMInferenceService backend
- `--simulator` - Deploy Model-A/Model-B simulators (no GPU required)
- `--no-public-route` - Skip creating public OpenShift Route (vSR accessed via MaaS)

### Step 4: Apply MaaS Integration

```bash
cd maas-integration
./apply-maas-integration.sh
cd ../../..
```

This creates:
- **ReferenceGrant** - Allows MaaS gateway to reference vSR service
- **HTTPRoute** - Routes `/v1/chat/*` from MaaS gateway to vSR service
- **AuthPolicy** - Requires valid MaaS token for `/v1/chat/*` requests

---

## Validation

### Get MaaS Host and Token

```bash
export MAAS_HOST=maas.$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')

export ACCESS_TOKEN=$(curl -sSk --oauth2-bearer "$(oc whoami -t)" \
  --json '{"expiration": "10m"}' \
  "https://${MAAS_HOST}/maas-api/v1/tokens" | jq -r .token)
```

### Test with Authentication (expect 200)

```bash
curl -sSk -X POST "https://${MAAS_HOST}/v1/chat/completions" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"model":"auto","messages":[{"role":"user","content":"Hello"}]}' | jq .
```

Expected: JSON response with `"model": "Model-A"` or `"Model-B"`

### Test without Authentication (expect 401)

```bash
curl -sSk -w "\nHTTP Status: %{http_code}\n" \
  -X POST "https://${MAAS_HOST}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"auto","messages":[{"role":"user","content":"test"}]}'
```

Expected: `HTTP Status: 401`

### Check Pod Status

```bash
oc get pods -n vllm-semantic-router-system
oc get llminferenceservices -n vllm-semantic-router-system
```

---

## Changes Required

### Semantic Router (vSR)

**No upstream code changes required for Phase 1.**

All integration is done via deployment manifests:

| File | Change |
|------|--------|
| `deploy/openshift/deploy-to-openshift.sh` | Added `--no-public-route` flag |
| `deploy/kserve/deploy.sh` | Added `--no-public-route` flag, updated "Next steps" output |
| `deploy/openshift/maas-integration/` | New directory with HTTPRoute, AuthPolicy, ReferenceGrant |
| `deploy/kserve/deployment.yaml` | Reduced CPU requests (1500m -> 500m) |
| `deploy/kserve/inference-examples/*.yaml` | Added container securityContext for OpenShift compatibility |

### Models-as-a-Service (MaaS)

**No changes required for basic auth.**

For token rate limiting to work on `/v1/chat/*`, the TokenRateLimitPolicy predicates need to match the auth identity structure. Current issue: the `tier` claim is not extracted for `/v1/chat/*` requests.

**Potential fix** (not implemented in Phase 1):
- Update `vsr-interim-auth-policy` to extract tier metadata from namespace name
- Or create a `/v1/chat/*`-specific TokenRateLimitPolicy with different predicates

---

## Integration Manifests

### HTTPRoute (`vsr-interim-httproute.yaml`)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: vsr-interim-route
  namespace: vllm-semantic-router-system
spec:
  parentRefs:
    - name: maas-default-gateway
      namespace: openshift-ingress
  hostnames:
    - "maas.${CLUSTER_DOMAIN}"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /v1/chat
      filters:
        - type: RequestHeaderModifier
          requestHeaderModifier:
            remove:
              - x-vsr-destination-endpoint
              - x-selected-model
      backendRefs:
        - name: semantic-router-kserve
          port: 8801
```

### AuthPolicy (`vsr-interim-auth-policy.yaml`)

```yaml
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: vsr-interim-auth-policy
  namespace: vllm-semantic-router-system
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: vsr-interim-route
  rules:
    authentication:
      service-accounts:
        kubernetesTokenReview:
          audiences:
            - maas-default-gateway-sa
        defaults:
          userid:
            expression: |
              auth.identity.user.username.split(":")[3]
          tier:
            expression: |
              auth.identity.user.username.split(":")[2].replace("maas-default-gateway-tier-", "")
        cache:
          key:
            selector: context.request.http.headers.authorization.@case:lower
          ttl: 600
    response:
      success:
        filters:
          identity:
            json:
              properties:
                userid:
                  expression: auth.identity.userid
                tier:
                  expression: auth.identity.tier
```

### ReferenceGrant (`vsr-reference-grant.yaml`)

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-maas-gateway-to-vsr
  namespace: vllm-semantic-router-system
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: openshift-ingress
  to:
    - group: ""
      kind: Service
      name: semantic-router-kserve
```

---

## Known Limitations

1. **No per-model RBAC on inference path** - vSR routes directly to model pods, bypassing MaaS SubjectAccessReview. The `/v1/chat/*` path doesn't map to a `/<namespace>/<model>` pattern, so path-based SAR doesn't apply.

2. **No billing integration** - `X-MaaS-Model-Executed` header not set for cost attribution.

3. **Tier extraction assumes namespace naming convention** - The AuthPolicy derives tier from the SA namespace (`maas-default-gateway-tier-<tier>`). If the MaaS tenant name changes, the extraction expression must be updated.

---

## Next Steps (Phase 2+)

1. **Single-gateway architecture** - vSR as ExtProc in MaaS gateway for full policy integration
2. **Model registry sync** - vSR discovers models from MaaS LLMInferenceService list
3. **Billing headers** - Set `X-MaaS-Model-Executed` for usage tracking

---

## Quick Reference

| Component | Namespace | Port |
|-----------|-----------|------|
| MaaS Gateway | openshift-ingress | 443 |
| Semantic Router | vllm-semantic-router-system | 8801 |
| Model-A | vllm-semantic-router-system | 8000 |
| Model-B | vllm-semantic-router-system | 8000 |

| Path | Handler |
|------|---------|
| `/maas-api/*` | MaaS API |
| `/<model>/v1/*` | MaaS -> KServe model |
| `/v1/chat/*` | MaaS -> vSR -> Model |

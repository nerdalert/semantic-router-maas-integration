# MaaS Integration for vLLM Semantic Router (Dual-Gateway)

This directory contains the manifests to integrate the vLLM Semantic Router (vSR) with Red Hat's Models-as-a-Service (MaaS) gateway using a dual-gateway architecture. The integration provides:

- OpenAI-compatible `/v1/chat/completions` endpoint with intelligent model routing
- MaaS token authentication (same tokens used for native MaaS models)
- Token rate limiting via the existing MaaS `TokenRateLimitPolicy` (shared budgets across all paths)

**Status:** Validated on OpenShift with KServe LLMInferenceService simulator backends.

---

## Architecture

### Dual-Gateway Overview

MaaS and vSR operate as separate services, each owning distinct URL paths through a shared gateway:

```
                                +------------------+
                                |     Client       |
                                +--------+---------+
                                         |
                          POST /v1/chat/completions
                          Authorization: Bearer <token>
                                         |
                                         v
                             +-----------+-----------+
                             |    MaaS Gateway       |
                             |  (openshift-ingress)  |
                             +-----------+-----------+
                                         |
                   +---------------------+---------------------+
                   |                     |                     |
                   v                     v                     v
         /maas-api/*            /<model>/v1/*            /v1/chat/*
                   |                     |                     |
                   v                     v                     v
         +----------------+    +----------------+    +-------------------+
         |   MaaS API     |    | Gateway        |    | vSR Route         |
         |   (tokens,     |    | AuthPolicy     |    | AuthPolicy        |
         |    models)      |    | (full stack)   |    | (token + tier)    |
         +----------------+    +-------+--------+    +--------+----------+
                                       |                      |
                                       v                      v
                               +-------+--------+   +--------+----------+
                               | KServe Model   |   | TokenRateLimitPolicy
                               | (direct)       |   | (gateway-level)   |
                               +----------------+   +--------+----------+
                                                              |
                                                              v
                                                   +----------+---------+
                                                   |  Semantic Router   |
                                                   |  (vSR + Envoy)    |
                                                   +----------+---------+
                                                              |
                                                 +------------+------------+
                                                 |                         |
                                                 v                         v
                                           +-----------+             +-----------+
                                           |  Model-A  |             |  Model-B  |
                                           |  (KServe) |             |  (KServe) |
                                           +-----------+             +-----------+
```

### Path Routing

| Path | Handler | Auth | Rate Limiting |
|------|---------|------|---------------|
| `/maas-api/*` | MaaS API (token minting, model discovery) | OpenShift user token | N/A |
| `/<model>/v1/*` | MaaS gateway -> KServe model (direct) | SA token + SAR RBAC | TokenRateLimitPolicy (per-user, per-tier) |
| `/v1/chat/*` | MaaS gateway -> vSR -> model (smart routing) | SA token (no SAR) | TokenRateLimitPolicy (per-user, per-tier, shared budget) |

### Why `/v1/chat/*`

This path is the standard OpenAI-compatible chat completions endpoint. It doesn't conflict with MaaS native model routes (`/<model>/v1/*`) because those always have a model-name prefix. No URL rewrite is needed -- the path passes through to vSR as-is.

---

## Components

### Manifests in This Directory

| File | Resource | Purpose |
|------|----------|---------|
| `vsr-interim-httproute.yaml` | HTTPRoute | Routes `/v1/chat/*` from MaaS gateway to vSR service |
| `vsr-interim-auth-policy.yaml` | AuthPolicy | Authenticates requests and extracts `userid` + `tier` for rate limiting |
| `vsr-reference-grant.yaml` | ReferenceGrant | Allows cross-namespace routing from MaaS gateway to vSR |
| `apply-maas-integration.sh` | Script | Applies all three manifests with variable substitution |

### External Dependencies (deployed by MaaS)

| Resource | Namespace | Purpose |
|----------|-----------|---------|
| `maas-default-gateway` (Gateway) | openshift-ingress | Ingress gateway for all MaaS traffic |
| `gateway-auth-policy` (AuthPolicy) | openshift-ingress | Auth for native model routes (overridden by vSR route policy) |
| `gateway-token-rate-limits` (TokenRateLimitPolicy) | openshift-ingress | Token-based rate limiting (shared across all gateway routes) |
| Authorino | kuadrant-system | Policy enforcement engine (handles AuthPolicy) |
| Limitador | kuadrant-system | Rate limiting engine (handles TokenRateLimitPolicy) |

---

## Traffic Flows

### Flow 1: Token Acquisition

```
Client                          MaaS Gateway                MaaS API
  |                                  |                          |
  |-- POST /maas-api/v1/tokens ----->|                          |
  |   Authorization: Bearer          |-- forward -------------->|
  |   <openshift-user-token>         |                          |
  |                                  |   1. Validate OpenShift  |
  |                                  |      user token          |
  |                                  |   2. Determine tier from |
  |                                  |      user groups         |
  |                                  |   3. Create SA in tier   |
  |                                  |      namespace           |
  |                                  |      (e.g., maas-default-|
  |                                  |       gateway-tier-free) |
  |                                  |   4. Issue SA token      |
  |<---- { "token": "eyJ..." } ------| <-----------------------|
```

The SA token subject encodes the tier in the namespace:
`system:serviceaccount:maas-default-gateway-tier-free:username-a1b2c3d4`

### Flow 2: Smart-Routed Inference (`/v1/chat/*`)

```
Client                MaaS Gateway           Authorino          Limitador          vSR              Model
  |                        |                     |                  |                |                |
  |-- POST /v1/chat/* ---->|                     |                  |                |                |
  |   Bearer <sa-token>    |                     |                  |                |                |
  |                        |                     |                  |                |                |
  |                        |-- 1. AuthPolicy --->|                  |                |                |
  |                        |   (vsr-interim)     |                  |                |                |
  |                        |                     |                  |                |                |
  |                        |   a. TokenReview: validate SA token    |                |                |
  |                        |   b. Extract userid: split(":")[3]     |                |                |
  |                        |      -> "username-a1b2c3d4"            |                |                |
  |                        |   c. Extract tier: split(":")[2]       |                |                |
  |                        |      .replace("maas-default-gateway-tier-","")          |                |
  |                        |      -> "free"                         |                |                |
  |                        |   d. Response filter: set              |                |                |
  |                        |      auth.identity.userid              |                |                |
  |                        |      auth.identity.tier                |                |                |
  |                        |                     |                  |                |                |
  |                        |-- 2. TRLP pre-check ----------------->|                |                |
  |                        |   predicate: tier == "free"            |                |                |
  |                        |   counter: userid                      |                |                |
  |                        |   check: tokens < 100/min?             |                |                |
  |                        |                     |     OK or 429    |                |                |
  |                        |                     |                  |                |                |
  |                        |-- 3. Forward to vSR ---------------------------------->|                |
  |                        |                     |                  |                |                |
  |                        |                     |                  |                |-- 4. Classify ->|
  |                        |                     |                  |                |    request      |
  |                        |                     |                  |                |    Select model |
  |                        |                     |                  |                |-- POST -------->|
  |                        |                     |                  |                |                |
  |                        |                     |                  |                |<-- response ----|
  |                        |                     |                  |                |  {usage:        |
  |                        |                     |                  |                |   total_tokens: |
  |                        |<--------------------------------- response ------------|   28}           |
  |                        |                     |                  |                |                |
  |                        |-- 5. TRLP post-count ---------------->|                |                |
  |                        |   Extract usage.total_tokens from body |                |                |
  |                        |   Increment counter by 28              |                |                |
  |                        |                     |                  |                |                |
  |<-- response -----------|                     |                  |                |                |
  |  {"model":"Model-B",   |                     |                  |                |                |
  |   "usage":{"total_tokens":28}}               |                  |                |                |
```

### Flow 3: Direct Model Inference (`/<model>/v1/*`)

```
Client                MaaS Gateway           Authorino          Limitador          KServe Model
  |                        |                     |                  |                |
  |-- POST /<ns>/<model>-->|                     |                  |                |
  |   /v1/chat/completions |                     |                  |                |
  |   Bearer <sa-token>    |                     |                  |                |
  |                        |-- 1. AuthPolicy --->|                  |                |
  |                        |   (gateway-level)   |                  |                |
  |                        |   a. TokenReview    |                  |                |
  |                        |   b. Extract userid |                  |                |
  |                        |   c. HTTP tier lookup (POST /v1/tiers/lookup)           |
  |                        |   d. SAR RBAC check (namespace + model from path)       |
  |                        |   e. Response filter: userid + tier    |                |
  |                        |                     |                  |                |
  |                        |-- 2. TRLP pre-check ----------------->|                |
  |                        |   (same policy, same counters)         |                |
  |                        |                     |                  |                |
  |                        |-- 3. Forward to model ------------------------------------>|
  |                        |                     |                  |                |
  |<-- response -----------|<---------------------------------------------- response --|
  |                        |-- 4. TRLP post-count ---------------->|                |
```

**Key difference between the two flows:**

| Aspect | `/v1/chat/*` (vSR) | `/<model>/v1/*` (direct) |
|--------|-------------------|-------------------------|
| AuthPolicy | Route-level (`vsr-interim`) | Gateway-level (`gateway-auth`) |
| Tier extraction | From SA namespace (no HTTP call) | HTTP call to `/v1/tiers/lookup` |
| Authorization (SAR) | Skipped (path doesn't encode model) | Checked (namespace/model from path) |
| TokenRateLimitPolicy | Same gateway-level policy | Same gateway-level policy |
| Counter key | `auth.identity.userid` (shared) | `auth.identity.userid` (shared) |
| Model selection | vSR classifies and routes | Client specifies model |

Both flows produce the same `auth.identity.userid` and `auth.identity.tier` values, so token budgets are **shared** across both paths.

---

## Token Rate Limiting (TRLP)

### How It Works

The `TokenRateLimitPolicy` is a Kuadrant CRD that counts tokens consumed from LLM response bodies and enforces per-user limits. It is deployed by MaaS at the **gateway level** and applies to all routes through the gateway.

```yaml
# gateway-token-rate-limits (deployed by MaaS in openshift-ingress)
apiVersion: kuadrant.io/v1alpha1
kind: TokenRateLimitPolicy
metadata:
  name: gateway-token-rate-limits
  namespace: openshift-ingress
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: maas-default-gateway
  limits:
    free-user-tokens:
      rates:
        - limit: 100
          window: 1m
      when:
        - predicate: auth.identity.tier == "free" && !request.path.endsWith("/v1/models")
      counters:
        - expression: auth.identity.userid
    premium-user-tokens:
      rates:
        - limit: 50000
          window: 1m
      when:
        - predicate: auth.identity.tier == "premium" && !request.path.endsWith("/v1/models")
      counters:
        - expression: auth.identity.userid
    enterprise-user-tokens:
      rates:
        - limit: 100000
          window: 1m
      when:
        - predicate: auth.identity.tier == "enterprise" && !request.path.endsWith("/v1/models")
      counters:
        - expression: auth.identity.userid
```

### TRLP Enforcement Flow

1. **Pre-check (request path):** Before forwarding the request, Limitador checks if the user's token counter has already exceeded their tier limit. If yes, return `429 Too Many Requests` immediately.

2. **Forward:** If the pre-check passes, the request is forwarded to the backend (vSR or direct model).

3. **Post-count (response path):** After receiving the response, Limitador extracts `usage.total_tokens` from the JSON response body and increments the user's counter. If the new total exceeds the limit, future requests will be rejected.

### Why the vSR AuthPolicy Is Required for TRLP

Kuadrant AuthPolicy has a **specificity hierarchy**: a route-level AuthPolicy overrides the gateway-level AuthPolicy for matching requests. Without the vSR route-level AuthPolicy populating `auth.identity.tier` and `auth.identity.userid`, the TRLP predicates would never match for `/v1/chat/*` traffic.

The vSR AuthPolicy extracts tier from the SA token subject without an HTTP call:

```
SA username: system:serviceaccount:maas-default-gateway-tier-free:user1-a1b2c3d4
                                   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
                                   split(":")[2] = "maas-default-gateway-tier-free"
                                   .replace("maas-default-gateway-tier-", "") = "free"
```

This works because MaaS creates service accounts in tier-specific namespaces at token issuance time (see `maas-api/internal/tier/mapper.go:ProjectedNsName()`).

### Shared Token Budgets

Because the TRLP targets the **Gateway** (not individual HTTPRoutes), and both the vSR AuthPolicy and gateway AuthPolicy produce the same `userid` counter key, token consumption is shared across all paths:

- A free-tier user gets **100 tokens/min total** across `/v1/chat/*` and `/<model>/v1/*`
- A premium user gets **50,000 tokens/min total**
- An enterprise user gets **100,000 tokens/min total**

If separate budgets are needed, create a route-level TokenRateLimitPolicy targeting `vsr-interim-route`.

---

## Installation

### Prerequisites

- OpenShift 4.18+ cluster
- `oc` CLI logged in with cluster-admin
- Kuadrant operator installed (provides Authorino + Limitador)
- KServe with LLMInferenceService CRD

### Step 1: Deploy MaaS

```bash
cd models-as-a-service/scripts
./deploy-rhoai-stable.sh
```

This deploys the MaaS gateway, AuthPolicy, and TokenRateLimitPolicy.

### Step 2: Deploy Semantic Router

```bash
cd semantic-router/deploy/openshift
./deploy-to-openshift.sh --kserve --simulator --no-public-route
```

Flags:
- `--kserve` -- Use KServe LLMInferenceService backend
- `--simulator` -- Deploy Model-A/Model-B simulators (no GPU required)
- `--no-public-route` -- Skip creating public OpenShift Route (vSR accessed via MaaS gateway)

### Step 3: Apply MaaS Integration

```bash
cd maas-integration
./apply-maas-integration.sh
```

This creates:
- **ReferenceGrant** -- Allows MaaS gateway to reference vSR service cross-namespace
- **HTTPRoute** -- Routes `/v1/chat/*` from MaaS gateway to vSR service
- **AuthPolicy** -- Validates MaaS tokens and extracts `userid` + `tier` for rate limiting

---

## Validation

### Get MaaS Host and Token

```bash
export MAAS_HOST="maas.$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')"

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

Expected: JSON response with `"model": "Model-A"` or `"Model-B"` and `usage.total_tokens`.

### Test without Authentication (expect 401)

```bash
curl -sSk -w "\nHTTP Status: %{http_code}\n" \
  -X POST "https://${MAAS_HOST}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"auto","messages":[{"role":"user","content":"test"}]}'
```

### Test Invalid Token (expect 401)

```bash
curl -sSk -w "\nHTTP Status: %{http_code}\n" \
  -X POST "https://${MAAS_HOST}/v1/chat/completions" \
  -H "Authorization: Bearer invalid-token" \
  -H "Content-Type: application/json" \
  -d '{"model":"auto","messages":[{"role":"user","content":"test"}]}'
```

### Test Token Rate Limiting (expect 429 after budget exhausted)

The free tier allows 100 tokens/min. Each response consumes ~20-50 tokens, so expect 429s after 3-5 requests:

```bash
for i in $(seq 1 10); do
  curl -sSk -o /dev/null -w "Request $i: %{http_code}\n" \
    -X POST "https://${MAAS_HOST}/v1/chat/completions" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"model":"auto","messages":[{"role":"user","content":"Write a long story about dragons"}]}'
done
```

Expected output:
```
Request 1: 200
Request 2: 200
Request 3: 200
Request 4: 429
Request 5: 429
...
```

### Check Limitador Metrics

```bash
oc port-forward -n kuadrant-system svc/limitador-limitador 8080:8080 &
curl -s http://localhost:8080/metrics | grep -E 'authorized_calls|limited_calls'
```

---

## Known Limitations

1. **No per-model RBAC on inference path** -- vSR routes directly to model pods, bypassing MaaS SubjectAccessReview. The `/v1/chat/*` path doesn't map to a `/<namespace>/<model>` pattern, so path-based SAR doesn't apply.

2. **No billing integration** -- `X-MaaS-Model-Executed` response header is not set for cost attribution.

3. **Tier extraction assumes namespace naming convention** -- The AuthPolicy derives tier from the SA namespace (`maas-default-gateway-tier-<tier>`). If the MaaS tenant name changes, the extraction expression in the AuthPolicy must be updated.

---

## Quick Reference

| Component | Namespace | Port |
|-----------|-----------|------|
| MaaS Gateway | openshift-ingress | 443 |
| Authorino | kuadrant-system | -- |
| Limitador | kuadrant-system | -- |
| Semantic Router | vllm-semantic-router-system | 8801 |
| Model-A | vllm-semantic-router-system | 8000 |
| Model-B | vllm-semantic-router-system | 8000 |

| Path | Handler |
|------|---------|
| `/maas-api/*` | MaaS API |
| `/<model>/v1/*` | MaaS -> KServe model (direct) |
| `/v1/chat/*` | MaaS -> vSR -> Model (smart routing) |

| Tier | Token Limit | Window |
|------|-------------|--------|
| free | 100 | 1 minute |
| premium | 50,000 | 1 minute |
| enterprise | 100,000 | 1 minute |

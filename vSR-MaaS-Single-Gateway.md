# Single-Gateway MaaS + vSR Deployment

## Dual-Gateway vs Single-Gateway Tradeoffs

- **Dual-gateway** (MaaS gateway + vSR gateway) keeps MaaS policies intact for `/llm/*` but requires a separate vSR policy set for `/vsr/*`. It is easier to get working quickly but duplicates auth/limit logic and complicates policy management.
    - Route ownership: MaaS controls `/llm/*` routes, while vSR owns `/vsr/*`. This splits enforcement and makes tier/rate policy consistency harder unless you duplicate policy logic.
- **Single-gateway** uses MaaS as the only entry point, so all auth/tiers/limits stay centralized. It requires pre-auth ExtProc to rewrite the path so SAR can authorize the selected model. That means the vSR decision happens before Authorino, and the request is rewritten to the MaaS `/llm/<model>` URL format so SAR can map to a specific `LLMInferenceService`.

What you can do with both:
- **Token validation and basic auth** work in both architectures.
- **Tier lookup and rate/token limits** can work in dual‑gateway only if you duplicate MaaS policy logic on the vSR gateway, because MaaS policies do not attach to `/vsr/*` (route is owned by the vSR gateway, not the MaaS gateway).
- **Single-gateway** is the only path that preserves MaaS policy ownership without duplicating policy manifests.
- **Dual-gateway** is useful for early demos or when you need vSR to remain a full gateway, but it drifts from MaaS policy semantics.

## Goal

Use the MaaS gateway as the only entry point for inference while keeping MaaS authorization, tiering, and rate limiting intact. vSR runs only as an ExtProc service for semantic routing.

## Key Constraint

MaaS authorization relies on SubjectAccessReview (SAR) for model access, which needs a specific model identity (LLMInferenceService) to authorize. In the single-gateway flow, vSR chooses the model dynamically, so the gateway must learn the model before SAR runs. This means the request must be rewritten to the MaaS model URL format before the Authorino filter performs SAR.

## How SubjectAccessReview (SAR) Works in MaaS

MaaS uses Authorino to call the Kubernetes SAR API to check whether the caller can access a specific `LLMInferenceService`. Authorino derives the resource identity from the HTTP request path (for example, `/llm/<model-name>/v1/chat/completions`). If the path does not contain a valid model name, SAR cannot map the request to a resource and authorization fails. In a single-gateway design, vSR must rewrite `/auto/...` to the MaaS model URL format before Authorino runs so SAR can validate access to the selected model.

## Proposed Flow (Single Gateway)

1. Client sends `POST /auto/v1/chat/completions` to the MaaS gateway with a bearer token.
2. Header sanitization runs first to strip any user-provided `X-MaaS-*` or `X-VSR-*` headers.
3. ExtProc runs before Authorino.
    - vSR classifies the request and selects a model.
    - vSR rewrites `:path` to `/llm/<model-id>/v1/chat/completions`.
    - vSR sets `X-MaaS-Model-Selected: <model-id>`.
4. Authorino executes authentication and authorization.
    - TokenReview validates the bearer token.
    - Tier lookup runs against MaaS API.
    - SAR authorizes access to the selected LLMInferenceService based on the rewritten path.
5. Rate limiting runs using `auth.metadata.matchedTier["tier"]` and `X-MaaS-Model-Selected`.
6. The MaaS gateway routes to the model backend via the standard MaaS HTTPRoute for `/llm/<model-id>/...`.
7. Response is returned to the client.

## Path Alignment With vSR Examples

The single-gateway flow does not require a hard-coded `/auto` path. We used `/auto` as an explicit entrypoint for MaaS, but to stay aligned with the vSR project examples you can use the standard vSR Envoy path and treat `model:"auto"` as the routing signal:

- **vSR example path:** `POST /v1/chat/completions` with `{"model":"auto", ...}`
- **Routing trigger:** ExtProc checks for `model == "auto"` and performs the same rewrite to `/llm/<maas_model_name>/v1/chat/completions`.
- **No change to MaaS APIs:** `/maas-api/*` and `/llm/*` remain pass-through.

If you keep `/auto`, ensure the MaaS gateway docs and validation examples consistently use that path. If you switch to `/v1/chat/completions`, update the ExtProc predicate and demo commands accordingly.

## Why ExtProc Must Precede Authorino

Authorino only sees the request as it exists at authorization time. To make SAR work, the model must be visible in the request path (or a header that Authorino is configured to use). Placing ExtProc before Authorino allows vSR to set the model and rewrite the path so Authorino can authorize correctly.

## Architecture (Target)

```
Client
  |
  v
MaaS Gateway (single entry point)
  1. Header sanitization
  2. ExtProc (vSR gRPC) -> selects model + rewrites path
  3. Authorino (TokenReview + tier + SAR)
  4. Limitador (tier + model)
  5. Route to /llm/<model>/... backend
```

## Changes Required (Hand-off Checklist)

1. Reorder gateway filters so ExtProc runs before Authorino.
    - Use EnvoyFilter to insert the ext_proc filter ahead of ext_authz.
    - Confirm Authorino still executes token review and SAR after path rewrite.
2. Update vSR ExtProc to perform a real path rewrite.
    - Input: `/auto/v1/chat/completions`
    - Output: `/llm/<model-id>/v1/chat/completions`
    - Set `X-MaaS-Model-Selected` header.
    - Ensure the selected model maps to a MaaS LLMInferenceService name (use `maas_model_name` in `model_config`).
3. Ensure MaaS Authorino policy uses SAR for LLMInferenceService.
    - SAR should resolve the model from the rewritten path.
    - Keep tier lookup and identity injection as-is.
4. Ensure MaaS rate-limit policies key off tier metadata and `X-MaaS-Model-Selected`.
    - Use `auth.metadata.matchedTier["tier"]` if `auth.identity.tier` is not injected.
5. Keep MaaS HTTPRoutes and policies as the sole route/policy definitions.
    - No separate vSR auth/rate-limit policies in vSR namespaces.
6. Validate traffic flow with normal MaaS tests plus `/auto` requests.

## Validation Steps

```bash
CLUSTER_DOMAIN=$(kubectl get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
MAAS_HOST="maas.${CLUSTER_DOMAIN}"
TOKEN=$(curl -sSk --oauth2-bearer "$(oc whoami -t)" \
  --json '{"expiration": "10m"}' "https://${MAAS_HOST}/maas-api/v1/tokens" | jq -r .token)

# Single-gateway vSR routing (auto)
curl -sSk -X POST "https://${MAAS_HOST}/auto/v1/chat/completions" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"model":"auto","messages":[{"role":"user","content":"What is 2+2?"}]}'

# Expect response model to be the routed backend
```

##  Open Questions

- Filter ordering: EnvoyFilter must ensure ext_proc runs before ext_authz on the MaaS gateway.
- Security: ExtProc will see unauthenticated requests unless a lightweight token presence check is added before it.
- SAR correctness: Authorino must resolve the model from the rewritten path, not from vSR headers.
- Model mapping: vSR model names must map to MaaS LLMInferenceService names or SAR will deny the request.
- Rate limiting: If tier metadata is not available where Limitador expects it, limit rules will not fire.
- vSR model registry: vSR must select only models that exist as LLMInferenceService resources.
- TRLP limitation (current): Token/RateLimitPolicy resources show Accepted/Enforced and the Limitador config is generated, but requests do not hit 429 yet. This indicates the rate‑limit filter or descriptors are not being applied to the MaaS gateway listener/route in this setup. Further debug is needed to confirm the ratelimit filter attachment and descriptor matching.

## Validation Checklist (Routing + Limits)

**Confirm vSR routing decisions**
- Check vSR logs for selected model:
```bash
oc logs -n vllm-semantic-router-system deployment/semantic-router | rg -i "selected model|Model-A|Model-B|route"
```

**Confirm backend model served**
- Inspect response headers and model field:

```bash
curl -sSk -D - -o /tmp/resp.json \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"model":"auto","messages":[{"role":"user","content":"What is 2+2?"}]}' \
  "https://${MAAS_HOST}/auto/v1/chat/completions"
jq -r '.model' /tmp/resp.json
```

**Confirm model pods are receiving traffic**
- Check recent logs on model pods:
```bash
oc logs -n vllm-semantic-router-system deployment/vllm-model-a --tail=50
oc logs -n vllm-semantic-router-system deployment/vllm-model-b --tail=50
```

**Confirm rate-limit resources are attached**
- Policy enforcement status:
```bash
oc get ratelimitpolicy -n openshift-ingress gateway-rate-limits -o jsonpath='{.status.conditions[*].type} {.status.conditions[*].status} {.status.conditions[*].message}'
oc get tokenratelimitpolicy -n openshift-ingress gateway-token-rate-limits -o jsonpath='{.status.conditions[*].type} {.status.conditions[*].status} {.status.conditions[*].message}'
```

## Summary

Single gateway is only viable if vSR can rewrite the request to MaaS model URL format before Authorino runs SAR. The core work is filter ordering plus a real path rewrite in the ExtProc service. Everything else should reuse MaaS policies and routes unchanged.

## Implementation Notes

### ExtProc Behavior

- Add early exit for non-`/auto` paths so `/maas-api/*` and `/llm/*` pass through unchanged.
- Rewrite `/auto/v1/chat/completions` to `/llm/<maas_model_name>/v1/chat/completions` after model selection.
- Set both `x-selected-model` and `x-maas-model-selected` headers.
- Use `maas_model_name` in `model_config` to map vSR model names to MaaS LLMInferenceService names.

### Envoy Filter Ordering

- Insert `ext_proc` first in the MaaS gateway filter chain.
- Add a Lua filter before `ext_proc` to strip `x-maas-*`, `x-vsr-*`, and `x-selected-model` headers from clients.
- Keep Authorino (`ext_authz`) after `ext_proc` so SAR sees the rewritten path.

### Model Mapping Warning

MaaS SAR uses the path segments to extract namespace and model name. If vSR uses names like `Model-A`/`Model-B` without mapping them to the LLMInferenceService name (e.g., `facebook-opt-125m-simulated`), SAR will deny the request.

## Demo: Token Minting + Authenticated Inference (Single Gateway)

**Summary**
- **Single entry point:** Client talks only to `maas.<cluster-domain>` for tokens and inference.
- **Auth flow:** TokenReview + tier lookup + SAR happen after vSR rewrites `/auto` to `/llm/<model>/...`.
- **Routing:** vSR selects the model, rewrites path, and sets `x-maas-model-selected`.
- **Limits:** Rate and token limits are enforced by MaaS policies using tier metadata.
- **Observability:** vSR logs show model selection, and MaaS policies apply to the rewritten request.

### Step-by-Step Traffic Flow

1. **Mint a MaaS token**
    - Client requests a short-lived token from MaaS.
    - MaaS validates the OpenShift user token.
    - MaaS returns a bearer token for inference.

2. **Client sends `/auto` inference request**
    - Client posts to `https://maas.<cluster-domain>/auto/v1/chat/completions`.
    - Authorization header contains the MaaS token.

3. **Gateway sanitizes headers**
    - Lua filter strips client-supplied `x-maas-*`, `x-vsr-*`, and `x-selected-model`.

4. **vSR ExtProc runs (pre-auth)**
    - vSR classifies the request.
    - vSR selects `Model-A` or `Model-B`.
    - vSR rewrites `:path` to `/llm/<maas_model_name>/v1/chat/completions`.
    - vSR rewrites request body model field to `maas_model_id` (e.g., `facebook/opt-125m`).
    - vSR sets `x-maas-model-selected` for policy/rate-limit attribution.

5. **Authorino authentication + authorization**
    - TokenReview validates the MaaS token.
    - Tier lookup resolves subscription tier.
    - SAR authorizes access to the LLMInferenceService from the rewritten path.

6. **Rate limiting / token limits**
    - Limitador enforces tier-based request and token limits.
    - Expected behavior:
        - Missing token yields `401`.
        - Excess requests yield `429` per tier policy (currently not observed; see TRLP limitation).

7. **Model inference**
    - MaaS HTTPRoute forwards the request to the selected model backend.
    - Response returns from the model via the MaaS gateway.

### Demo Commands

```bash
# 1) Get gateway host
CLUSTER_DOMAIN=$(kubectl get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
MAAS_HOST="maas.${CLUSTER_DOMAIN}"

# 2) Mint token
TOKEN_RESPONSE=$(curl -sSk --oauth2-bearer "$(oc whoami -t)" \
  --json '{"expiration": "10m"}' "https://${MAAS_HOST}/maas-api/v1/tokens")
TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r .token)

# 3) Verify MaaS model list
curl -sSk "https://${MAAS_HOST}/maas-api/v1/models" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" | jq -r .

# 4) Inference via /auto (vSR + MaaS)
curl -sSk -X POST "https://${MAAS_HOST}/auto/v1/chat/completions" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"model":"auto","messages":[{"role":"user","content":"What is 2+2?"}]}'

# 4a) Show the actual backend model that served the request
curl -sSk -D - -o /tmp/auto-response.json \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"model":"auto","messages":[{"role":"user","content":"What is 2+2?"}]}' \
  "https://${MAAS_HOST}/auto/v1/chat/completions"
jq -r '.model' /tmp/auto-response.json

# 5) No-token check (expect 401)
curl -sSk -X POST "https://${MAAS_HOST}/auto/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"auto","messages":[{"role":"user","content":"Hello"}]}' -v

# 6) Rate-limit check (expect 429 after limit for your tier)
# NOTE: 429 is not currently observed in this setup; see TRLP limitation above.
for i in {1..16}; do
  curl -sSk -o /dev/null -w "%{http_code}\n" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"model":"auto","messages":[{"role":"user","content":"Hello"}]}' \
    "https://${MAAS_HOST}/auto/v1/chat/completions"
done
```

## Model-A/Model-B vs KServe (MaaS)

- In the **vanilla vSR deployment**, `Model-A` and `Model-B` are vLLM backends created by the vSR deployment (not KServe).
- In the **single‑gateway MaaS flow**, vSR does not serve models directly; it rewrites to MaaS `/llm/<model>` routes backed by KServe `LLMInferenceService` resources.
- vSR does **not** require KServe to operate; it routes to any HTTP backend. KServe is used here because MaaS model serving is KServe‑backed.
- If you want `Model-A`/`Model-B` to be distinct KServe models under MaaS, create two `LLMInferenceService` resources and map each vSR model to its corresponding `maas_model_name`/`maas_model_id`.
    - Architecture change: MaaS will expose two `/llm/<model>` routes, SAR will authorize per‑model, and Limitador will enforce limits per model route instead of a single shared simulator backend.

## Requirements Coverage Matrix (Proposal vs. Deployments)

| Initial Requirements | Two-Gateway (this doc) | Single-Gateway (`SINGLE_GW_DEPLOYMENT.md`) | Notes |
| --- | --- | --- | --- |
| Token validation (TokenReview) | Yes | Yes | Two-gateway uses `vsr-interim-auth-policy` on `/vsr/*`. |
| Tier resolution | No | Not documented | Proposal expects MaaS tier lookup before routing. |
| Context injection headers (user/tier/groups) | Partial | Partial | Two-gateway injects username/groups only; tier header not present. |
| RBAC (SubjectAccessReview) | No | Not documented | Not enabled for `/vsr/*` in interim policy. |
| Per-model rate limiting via `X-MaaS-Model-Selected` | No | Not documented | Requires model-aware limits after selection. |
| Header sanitization (strip `X-MaaS-*`, `X-VSR-*`) | No | Yes | Single-gw flow calls out Lua header sanitization. |
| Filter chain order (Auth → vSR → model Auth → limits) | No | Partial | Single-gw shows Auth → ExtProc → route override; model Auth/limits not shown. |
| Adaptive fallback on 429 (Phase 4.5) | No | No | Requires Lua/WASM + vSR fallback API. |
| Semantic routing RBAC resource | No | No | Not implemented in either deployment. |
| Billing uses executed model headers | No | No | Needs `X-MaaS-Model-Executed` and collector updates. |
| vSR ExtProc integration | No | Yes | Two-gateway uses vSR Envoy; single-gw uses ExtProc in MaaS gateway. |
| Multi-tenant cache isolation | No | Not documented | Requires `X-User-ID` scoping in vSR. |
| Model registry sync | No | No | Requires MaaS model registry integration. |
| Fallback resolution API | No | No | Required for Phase 4.5 fallback. |
| Transparent observability headers | No | Not documented | Proposal expects selection/executed/fallback headers. |

## TODO

- Create two KServe models for Model-A/Model-B and map them via `maas_model_name`/`maas_model_id`.
- Resolve TRLP enforcement so rate limiting returns `429` as expected.

## Required Changes for MaaS (Models-as-a-Service)

MaaS uses the `/v1/tiers/lookup` result to populate `auth.metadata.matchedTier["tier"]` during the auth pipeline. Rate and token limit policies should key off `auth.metadata.matchedTier["tier"]`, and use `auth.identity.userid` as the counter so limits are enforced per authenticated identity.

Required changes:
- `models-as-a-service/deployment/base/policies/usage-policies/rate-limit-policy.yaml`
- `models-as-a-service/deployment/base/policies/usage-policies/token-limit-policy.yaml`

Example predicate:
```yaml
when:
  - predicate: |
      auth.metadata.matchedTier["tier"] == "free"
```

Example counter:
```yaml
counters:
  - expression: auth.identity.userid
```

## Required Changes for Semantic Router (vSR ExtProc)

These changes make the single-gateway flow compatible with MaaS auth, SAR, and tiered limits without adding vSR-specific policies.

- `semantic-router/src/semantic-router/pkg/extproc/processor_req_body.go`
    - **Non-auto pass-through:** Return early for any path that does not start with `/auto/` so MaaS `/maas-api/*` and `/llm/*` routes remain unchanged.
        - Scope: gate the vSR rewrite/mutation logic strictly to `/auto` (or `/v1/chat/completions` with `model:"auto"` if you switch paths).
    - **Path rewrite:** After routing, rewrite `:path` from `/auto/v1/chat/completions` to `/llm/<maas_model_name>/v1/chat/completions` so SAR can map to the LLMInferenceService.
        - Result: Authorino SAR sees the correct model name in the path and authorizes the LLMInferenceService.
    - **Header injection:** Set `x-maas-model-selected` (and keep `x-selected-model`) to communicate the routed backend to MaaS policies and logs.
        - Usage: header is used for policy attribution and can be scrubbed by the gateway Lua filter on ingress.
    - **Body rewrite:** Update the JSON `model` field to the MaaS model ID (for example, `facebook/opt-125m`) so the model server sees the correct ID.
        - Reason: MaaS model backends expect MaaS model IDs, not vSR-friendly aliases.
    - **Model mapping:** Add `maas_model_name` and `maas_model_id` to vSR `model_config` and use them when selecting the routed backend.
        - Mapping: vSR `Model-A`/`Model-B` → MaaS `facebook-opt-125m-simulated` and `facebook/opt-125m`.
- `semantic-router/src/semantic-router/pkg/headers/headers.go`
    - Add a constant for `x-maas-model-selected` so it is set and can be sanitized consistently by the gateway header-cleaning filter.
        - Consistency: keeps header naming centralized for both injection and removal.
- `semantic-router/deploy/openshift/config-openshift.yaml`
    - **Disable semantic cache when ExtProc runs pre-auth:** set `semantic_cache.enabled: false` so unauthenticated requests cannot be served from cache before Authorino runs.
        - Security: avoids cache-hit short‑circuiting that bypasses MaaS auth and rate limiting.


### Build

```
 # Build
  docker build -f tools/docker/Dockerfile.extproc -t ghcr.io/nerdalert/semantic-router-extproc:latest .

  # Push
  docker push ghcr.io/nerdalert/semantic-router-extproc:latest
```


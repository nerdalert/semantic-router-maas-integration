#!/bin/bash
# Apply MaaS integration manifests for semantic router
# This connects the MaaS gateway to the semantic router, enabling:
# - MaaS token authentication on /v1/chat/* paths
# - Rate limiting through MaaS policies
# - Intelligent routing via semantic router
#
# Usage: ./apply-maas-integration.sh [--namespace NAMESPACE]
#
# Defaults to 'vllm-semantic-router-system' if not specified

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Default namespace
VSR_NAMESPACE="vllm-semantic-router-system"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--namespace)
            VSR_NAMESPACE="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--namespace NAMESPACE]"
            echo ""
            echo "Options:"
            echo "  -n, --namespace   Namespace where semantic-router is deployed (default: vllm-semantic-router-system)"
            echo "  -h, --help        Show this help message"
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            exit 1
            ;;
    esac
done

log "Applying MaaS integration for semantic router in namespace: $VSR_NAMESPACE"

# Get cluster domain
CLUSTER_DOMAIN=$(kubectl get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null)
if [[ -z "$CLUSTER_DOMAIN" ]]; then
    error "Could not detect cluster domain. Are you connected to an OpenShift cluster?"
    exit 1
fi

log "Cluster domain: $CLUSTER_DOMAIN"

# Check if semantic-router service exists
if ! kubectl get service semantic-router-kserve -n "$VSR_NAMESPACE" &>/dev/null; then
    error "semantic-router-kserve service not found in namespace $VSR_NAMESPACE"
    echo "  Deploy semantic router first with: ./deploy-to-openshift.sh --kserve --simulator"
    exit 1
fi

# Check if MaaS gateway exists
if ! kubectl get gateway maas-default-gateway -n openshift-ingress &>/dev/null; then
    error "maas-default-gateway not found in openshift-ingress namespace"
    echo "  Deploy MaaS first with: models-as-a-service/scripts/deploy-rhoai-stable.sh"
    exit 1
fi

log "Verified prerequisites: semantic-router and MaaS gateway exist"

# Apply ReferenceGrant (in vSR namespace to allow cross-namespace routing)
log "Applying ReferenceGrant..."
cat <<EOF | kubectl apply -n "$VSR_NAMESPACE" -f -
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-maas-gateway-to-vsr
  labels:
    app: semantic-router
    integration: maas
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: openshift-ingress
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: ${VSR_NAMESPACE}
  to:
    - group: ""
      kind: Service
      name: semantic-router-kserve
EOF
success "ReferenceGrant applied"

# Apply HTTPRoute (in vSR namespace, targeting MaaS gateway)
log "Applying HTTPRoute..."
cat <<EOF | kubectl apply -n "$VSR_NAMESPACE" -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: vsr-interim-route
  labels:
    app: semantic-router
    integration: maas
spec:
  parentRefs:
    - name: maas-default-gateway
      namespace: openshift-ingress
      sectionName: https
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
          namespace: ${VSR_NAMESPACE}
          port: 8801
EOF
success "HTTPRoute applied"

# Apply AuthPolicy (in vSR namespace, targeting the HTTPRoute)
# Extracts userid and tier from the SA token so the gateway TokenRateLimitPolicy
# can enforce shared token budgets across /v1/chat/* and /<model>/v1/* paths.
# Tier is derived from the SA namespace (e.g., maas-default-gateway-tier-free -> free).
log "Applying AuthPolicy..."
cat <<EOF | kubectl apply -n "$VSR_NAMESPACE" -f -
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: vsr-interim-auth-policy
  labels:
    app: semantic-router
    integration: maas
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
EOF
success "AuthPolicy applied"

echo ""
success "MaaS integration complete!"
echo ""
echo "Test the integration:"
echo ""
echo "1. Get MaaS host and token:"
echo "   export MAAS_HOST=\"maas.${CLUSTER_DOMAIN}\""
echo "   export ACCESS_TOKEN=\$(curl -sSk --oauth2-bearer \"\$(oc whoami -t)\" \\"
echo "     --json '{\"expiration\": \"10m\"}' \\"
echo "     \"https://\${MAAS_HOST}/maas-api/v1/tokens\" | jq -r .token)"
echo ""
echo "2. Test semantic routing through MaaS gateway:"
echo "   curl -sSk -X POST \"https://\${MAAS_HOST}/v1/chat/completions\" \\"
echo "     -H \"Authorization: Bearer \${ACCESS_TOKEN}\" \\"
echo "     -H \"Content-Type: application/json\" \\"
echo "     -d '{\"model\":\"auto\",\"messages\":[{\"role\":\"user\",\"content\":\"What is 2+2?\"}]}'"
echo ""
echo "3. Test without token (should return 401):"
echo "   curl -sSk -w '\\nHTTP Status: %{http_code}\\n' \\"
echo "     -X POST \"https://\${MAAS_HOST}/v1/chat/completions\" \\"
echo "     -H \"Content-Type: application/json\" \\"
echo "     -d '{\"model\":\"auto\",\"messages\":[{\"role\":\"user\",\"content\":\"test\"}]}'"
echo ""

#!/bin/bash
# Script to test InferenceService via Envoy Gateway (production-like setup)

NAMESPACE="kserve-test"
SERVICE_NAME="sklearn-iris"
GATEWAY_NAMESPACE="envoy-gateway-system"
LOCAL_PORT=8082

# Check if port is already in use, try alternative ports
if lsof -Pi :${LOCAL_PORT} -sTCP:LISTEN -t >/dev/null 2>&1 ; then
    echo "Port ${LOCAL_PORT} is already in use, trying alternative ports..."
    for alt_port in 8083 8084 8085 9000; do
        if ! lsof -Pi :${alt_port} -sTCP:LISTEN -t >/dev/null 2>&1 ; then
            LOCAL_PORT=${alt_port}
            echo "Using port ${LOCAL_PORT} instead"
            break
        fi
    done
    if [ ${LOCAL_PORT} -eq 8082 ]; then
        echo "Warning: Could not find available port, will try anyway..."
    fi
fi

echo "1. Checking InferenceService status..."
kubectl get inferenceservice ${SERVICE_NAME} -n ${NAMESPACE}

echo ""
echo "2. Getting InferenceService URL..."
SERVICE_HOSTNAME=$(kubectl get inferenceservice ${SERVICE_NAME} -n ${NAMESPACE} -o jsonpath='{.status.url}' | cut -d "/" -f 3)
if [ -z "$SERVICE_HOSTNAME" ]; then
    echo "Error: Could not get InferenceService URL. Is the InferenceService ready?"
    exit 1
fi
echo "Service Hostname: ${SERVICE_HOSTNAME}"

echo ""
echo "3. Finding Envoy Gateway service..."
# Envoy Gateway creates Envoy proxy services in envoy-gateway-system namespace
# Service name pattern: envoy-<gateway-namespace>-<gateway-name>-<hash>
# First, find the Gateway resource
GATEWAY_NAME=$(kubectl get gateway -n kserve -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$GATEWAY_NAME" ]; then
    echo "Error: Could not find Gateway resource in namespace kserve"
    exit 1
fi
echo "Found Gateway: ${GATEWAY_NAME} in namespace kserve"

# Envoy Gateway creates service with pattern: envoy-<namespace>-<gateway-name>-<hash>
# Try to find service in envoy-gateway-system namespace with pattern matching
ENVOY_SERVICE=$(kubectl get svc -n ${GATEWAY_NAMESPACE} 2>/dev/null | grep "envoy-kserve-${GATEWAY_NAME}" | awk '{print $1}' | head -1)

# If not found, try finding any service with envoy-<namespace>-<gateway-name> pattern
if [ -z "$ENVOY_SERVICE" ]; then
    ENVOY_SERVICE=$(kubectl get svc -n ${GATEWAY_NAMESPACE} 2>/dev/null | grep -E "envoy-.*-${GATEWAY_NAME}" | awk '{print $1}' | head -1)
fi

# If still not found, try finding service with label gateway.envoyproxy.io/owning-gateway-namespace
if [ -z "$ENVOY_SERVICE" ]; then
    ENVOY_SERVICE=$(kubectl get svc -n ${GATEWAY_NAMESPACE} -l gateway.envoyproxy.io/owning-gateway-namespace=kserve,gateway.envoyproxy.io/owning-gateway-name=${GATEWAY_NAME} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
fi

# If still not found, try finding any service with envoy prefix that has HTTP port
if [ -z "$ENVOY_SERVICE" ]; then
    # Get all services with envoy prefix and check if they have port 80
    for svc in $(kubectl get svc -n ${GATEWAY_NAMESPACE} 2>/dev/null | grep "^envoy-" | awk '{print $1}'); do
        PORT=$(kubectl get svc -n ${GATEWAY_NAMESPACE} ${svc} -o jsonpath='{.spec.ports[?(@.port==80)].port}' 2>/dev/null)
        if [ "$PORT" = "80" ]; then
            ENVOY_SERVICE=${svc}
            break
        fi
    done
fi

if [ -z "$ENVOY_SERVICE" ]; then
    echo "Error: Could not find Envoy Gateway service"
    echo "Looking for service matching pattern: envoy-kserve-${GATEWAY_NAME}-*"
    echo ""
    echo "Available services in ${GATEWAY_NAMESPACE} namespace:"
    kubectl get svc -n ${GATEWAY_NAMESPACE} 2>/dev/null || echo "Namespace ${GATEWAY_NAMESPACE} not found"
    exit 1
fi

ENVOY_NAMESPACE=${GATEWAY_NAMESPACE}
echo "Found Envoy Gateway service: ${ENVOY_SERVICE} in namespace ${ENVOY_NAMESPACE}"

# Get the port from service (usually port 80 for HTTP or 443 for HTTPS)
SERVICE_PORT=$(kubectl get svc -n ${ENVOY_NAMESPACE} ${ENVOY_SERVICE} -o jsonpath='{.spec.ports[?(@.name=="http")].port}' 2>/dev/null)
if [ -z "$SERVICE_PORT" ]; then
    SERVICE_PORT=$(kubectl get svc -n ${ENVOY_NAMESPACE} ${ENVOY_SERVICE} -o jsonpath='{.spec.ports[?(@.port==80)].port}' 2>/dev/null)
fi
if [ -z "$SERVICE_PORT" ]; then
    SERVICE_PORT=$(kubectl get svc -n ${ENVOY_NAMESPACE} ${ENVOY_SERVICE} -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)
fi
if [ -z "$SERVICE_PORT" ]; then
    SERVICE_PORT=80  # Default to port 80
fi

echo "Service port: ${SERVICE_PORT}"

echo ""
echo "4. Port-forwarding Envoy Gateway service..."
echo "Port-forwarding: local:${LOCAL_PORT} -> ${ENVOY_NAMESPACE}/${ENVOY_SERVICE}:${SERVICE_PORT}"
kubectl port-forward -n ${ENVOY_NAMESPACE} svc/${ENVOY_SERVICE} ${LOCAL_PORT}:${SERVICE_PORT} &
PORT_FORWARD_PID=$!

echo "Port-forward started (PID: ${PORT_FORWARD_PID})"
echo "Waiting 3 seconds for port-forward to establish..."
sleep 3

echo ""
echo "5. Testing inference through Envoy Gateway..."
echo "Using local port: ${LOCAL_PORT}"
echo "Service Hostname: ${SERVICE_HOSTNAME}"
echo ""

# Try HTTP first with follow redirects and HOST header
echo "Sending POST request to inference endpoint via Gateway..."
RESPONSE=$(curl -s -w "\n%{http_code}" -L -k \
  -H "Host: ${SERVICE_HOSTNAME}" \
  -H "Content-Type: application/json" \
  "http://localhost:${LOCAL_PORT}/v1/models/sklearn-iris:predict" \
  -d @./iris-input.json)

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
    echo "✅ Inference successful!"
    echo "Response:"
    echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"
elif [ "$HTTP_CODE" = "307" ] || [ "$HTTP_CODE" = "301" ] || [ "$HTTP_CODE" = "302" ]; then
    echo "Service redirects to HTTPS, trying HTTPS directly..."
    curl -v -k \
      -H "Host: ${SERVICE_HOSTNAME}" \
      -H "Content-Type: application/json" \
      "https://localhost:${LOCAL_PORT}/v1/models/sklearn-iris:predict" \
      -d @./iris-input.json
else
    echo "❌ Inference failed with HTTP code: ${HTTP_CODE}"
    echo "Response:"
    echo "$BODY"
    echo ""
    echo "Troubleshooting:"
    echo "1. Check if Gateway is ready: kubectl get gateway -n kserve"
    echo "2. Check if HTTPRoute exists: kubectl get httproute -n ${NAMESPACE}"
    echo "3. Check Envoy Gateway logs: kubectl logs -n ${GATEWAY_NAMESPACE} -l app.kubernetes.io/name=envoy-gateway"
fi

echo ""
echo ""
echo "6. To stop port-forward, run: kill ${PORT_FORWARD_PID}"

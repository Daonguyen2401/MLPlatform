#!/bin/bash
# Script to test InferenceService via port-forward

NAMESPACE="kserve-test"
SERVICE_NAME="sklearn-iris"
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
echo "2. Getting service name for port-forward..."
# KServe creates a service for each InferenceService
# The service name is typically: <inferenceservice-name>-predictor-default
SERVICE=$(kubectl get svc -n ${NAMESPACE} | grep ${SERVICE_NAME} | grep predictor | awk '{print $1}' | head -1)

if [ -z "$SERVICE" ]; then
    echo "Service not found. Trying alternative method - port-forward directly to pod..."
    # Alternative: port-forward directly to the pod
    POD=$(kubectl get pods -n ${NAMESPACE} -l serving.kserve.io/inferenceservice=${SERVICE_NAME} | grep predictor | awk '{print $1}' | head -1)
    if [ -z "$POD" ]; then
        echo "Error: Could not find service or pod for ${SERVICE_NAME}"
        exit 1
    fi
    echo "Port-forwarding to pod: ${POD} (container port 8080)"
    kubectl port-forward -n ${NAMESPACE} pod/${POD} ${LOCAL_PORT}:8080 &
    PORT_FORWARD_PID=$!
    SERVICE_PORT=8080
else
    echo "Found service: ${SERVICE}"
    # Get the port from service (usually port 80 for HTTP)
    SERVICE_PORT=$(kubectl get svc -n ${NAMESPACE} ${SERVICE} -o jsonpath='{.spec.ports[0].port}')
    if [ -z "$SERVICE_PORT" ]; then
        SERVICE_PORT=80  # Default to port 80
    fi
    echo "Service port: ${SERVICE_PORT}"
    echo "Port-forwarding to service: ${SERVICE} (local:${LOCAL_PORT} -> service:${SERVICE_PORT})"
    kubectl port-forward -n ${NAMESPACE} svc/${SERVICE} ${LOCAL_PORT}:${SERVICE_PORT} &
    PORT_FORWARD_PID=$!
fi

echo "Port-forward started (PID: ${PORT_FORWARD_PID})"
echo "Waiting 3 seconds for port-forward to establish..."
sleep 3

echo ""
echo "3. Testing inference..."
echo "Using local port: ${LOCAL_PORT}"

# Try HTTP first with follow redirects
echo "Sending POST request to inference endpoint..."
RESPONSE=$(curl -s -w "\n%{http_code}" -L -k -H "Content-Type: application/json" \
  http://localhost:${LOCAL_PORT}/v1/models/sklearn-iris:predict \
  -d @./iris-input.json)

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
    echo "✅ Inference successful!"
    echo "Response:"
    echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"
elif [ "$HTTP_CODE" = "307" ] || [ "$HTTP_CODE" = "301" ] || [ "$HTTP_CODE" = "302" ]; then
    echo "Service redirects to HTTPS, trying HTTPS directly..."
    curl -v -k -H "Content-Type: application/json" \
      https://localhost:${LOCAL_PORT}/v1/models/sklearn-iris:predict \
      -d @./iris-input.json
else
    echo "❌ Inference failed with HTTP code: ${HTTP_CODE}"
    echo "Response:"
    echo "$BODY"
fi

echo ""
echo ""
echo "4. To stop port-forward, run: kill ${PORT_FORWARD_PID}"

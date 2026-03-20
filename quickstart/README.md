# KServe Inference Quickstart

This guide walks through deploying an InferenceService and testing it via Envoy Gateway on Minikube.

## Prerequisites

- Minikube cluster running
- KServe installed via Helm + ArgoCD
- Envoy Gateway installed with `gateway-helm`
- `kubectl` configured for the cluster

## Architecture

```
Client → Envoy Gateway (NodePort) → HTTPRoute → InferenceService ClusterIP → Model Pod
```

## Steps

### 1. Deploy the InferenceService

```bash
kubectl apply -f iris.yaml
```

Wait for the model to be ready:

```bash
kubectl get inferenceservice -n kserve-test
```

Expected output:
```
NAME           URL                                           READY   AGE
sklearn-iris   http://sklearn-iris-kserve-test.<DOMAIN>     True    ...
```

> **Note:** The `<DOMAIN>` is configured via `kserve.controller.gateway.domain` in `kserve/values.yaml`. For Minikube, it should be `192.168.49.2.sslip.io`.

### 2. Check the HTTPRoute

KServe creates a Gateway API HTTPRoute to route traffic through Envoy Gateway:

```bash
kubectl get httproute -n kserve-test
```

Expected output:
```
NAME                     HOSTNAMES                                                      AGE
sklearn-iris            [sklearn-iris-kserve-test.192.168.49.2.sslip.io]            1m
sklearn-iris-predictor  [sklearn-iris-predictor-kserve-test.192.168.49.2.sslip.io] 1m
```

### 3. Verify the Gateway is Programmed

```bash
kubectl get gateway -n kserve
```

Expected output:
```
NAME                    CLASS   ADDRESS        PROGRAMMED   AGE
kserve-ingress-gateway  envoy   192.168.49.2   True         ...
```

If `PROGRAMMED` is `False`, check the Envoy proxy pod status:
```bash
kubectl get pods -n envoy-gateway-system -l app.kubernetes.io/name=envoy
```

### 4. Test Inference

Find the Envoy Gateway service and port-forward to it:

```bash
# Get the NodePort HTTP port
kubectl get svc -n envoy-gateway-system -o jsonpath='{.items[?(@.metadata.name~"envoy-kserve")].spec.ports[?(@.name=="http")].nodePort}'

# Or use the default port-forward approach
kubectl port-forward -n envoy-gateway-system svc/envoy-kserve-kserve-ingress-gateway-deaaa49b 8082:80
```

In another terminal, send an inference request:

```bash
curl -H "Host: sklearn-iris-kserve-test.192.168.49.2.sslip.io" \
     -H "Content-Type: application/json" \
     "http://localhost:8082/v1/models/sklearn-iris:predict" \
     -d '{
       "instances": [
         [5.1, 3.5, 1.4, 0.2],
         [7.0, 3.2, 4.7, 1.4],
         [6.3, 3.3, 6.0, 2.5]
       ]
     }'
```

Expected response:
```json
{"predictions": [0, 1, 2]}
```

Class labels:
- `0` → Setosa
- `1` → Versicolor
- `2` → Virginica

### 5. Using the Test Script

A convenience script is provided:

```bash
bash test-inference-gateway.sh
```

## Troubleshooting

### Gateway not Programmed

If `PROGRAMMED` is `False` with `AddressNotAssigned`:

1. Check the Envoy Gateway managed service type:
   ```bash
   kubectl get svc -n envoy-gateway-system -o jsonpath='{.items[?(@.metadata.name~"envoy-kserve")].spec.type}'
   ```
   Should be `NodePort`, not `LoadBalancer`.

2. Check the Envoy proxy pods:
   ```bash
   kubectl get pods -n envoy-gateway-system -l app.kubernetes.io/name=envoy
   ```

3. Restart Envoy Gateway if pods are crashing:
   ```bash
   kubectl rollout restart deployment/envoy-gateway -n envoy-gateway-system
   ```

### Inference returns 404

1. Verify HTTPRoute exists and is `Accepted`:
   ```bash
   kubectl get httproute -n kserve-test -o yaml | grep -A 5 "conditions:"
   ```

2. Check the `Host` header matches the HTTPRoute hostname exactly.

### Inference returns 503

1. Verify the model pod is running:
   ```bash
   kubectl get pods -n kserve-test
   ```

2. Check if the service can reach the pod directly:
   ```bash
   kubectl run -it --rm debug --image=busybox --restart=Never -- \
     wget -qO- sklearn-iris-predictor.kserve-test.svc.cluster.local:80
   ```

## Configuration Notes

### Key Values in `kserve/values.yaml`

| Key | Value | Description |
|-----|-------|-------------|
| `controller.deploymentMode` | `Standard` | RawDeployment mode (not Knative Serverless) |
| `gateway.disableIngressCreation` | `false` | KServe creates HTTPRoute automatically |
| `gateway.domain` | `192.168.49.2.sslip.io` | Resolvable domain for Minikube |
| `gateway.ingressGateway.enableGatewayApi` | `true` | Use Gateway API for routing |
| `gateway.ingressGateway.kserveGateway` | `kserve/kserve-ingress-gateway` | Gateway for KServe traffic |

### Key Values in `gateway-helm/templates/envoy-proxy.yaml`

```yaml
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyService:
        type: NodePort  # Use NodePort instead of LoadBalancer for Minikube
```

The EnvoyProxy is linked to the GatewayClass via `parametersRef` in `kserve/templates/gatewayclass.yaml`.

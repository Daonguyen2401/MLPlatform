# MLPlatform

A self-hosted ML model serving platform built on [KServe](https://kserve.github.io/website/), [Envoy Gateway](https://gateway.envoyproxy.io/), and [ArgoCD](https://argo-cd.readthedocs.io/) — designed for Minikube (bare-metal/on-prem).

---

## Architecture Overview

```
Internet
    │
    ▼
┌─────────────────────────────────────────────────────────────┐
│  Minikube Cluster                                           │
│                                                             │
│  ┌──────────────┐                                          │
│  │  Envoy       │  ◄── GatewayClass (envoy)               │
│  │  Gateway     │      + parametersRef ──► EnvoyProxy     │
│  │  Controller  │                                          │
│  └──────┬───────┘                                          │
│         │                                                   │
│         ▼                                                   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Envoy Proxy Deployment (Envoy Data Plane)          │   │
│  │  Labels: app.kubernetes.io/managed-by=envoy-gateway│   │
│  │  │                                                   │   │
│  │  └── Envoy Pod ── receives & routes traffic          │   │
│  └──────────────────────────┬────────────────────────────┘   │
│                             │                                │
│                             ▼                                │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  NodePort Service (HTTP:30757 / HTTPS:31481)       │   │
│  │  Labels: gateway.envoyproxy.io/owning-gateway-*    │   │
│  └─────────────────────────────────────────────────────┘   │
│                            │                                │
│                            ▼  (external traffic)            │
│                    ┌───────────────┐                       │
│                    │  Minikube Node │  :30757 (HTTP)        │
│                    │  192.168.49.2  │  :31481 (HTTPS)       │
│                    └───────────────┘                       │
│                            │                                │
└────────────────────────────│────────────────────────────────┘
                             │
                             ▼ (HTTP request with Host header)
┌─────────────────────────────────────────────────────────────┐
│  HTTPRoute (kserve-test/sklearn-iris)                     │
│  Host: sklearn-iris-kserve-test.192.168.49.2.sslip.io   │
│  │                                                   │   │
│  └── ParentRef: kserve/kserve-ingress-gateway          │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  InferenceService (sklearn-iris) — Standard mode   │   │
│  │  Annotation: serving.kserve.io/deploymentMode=Standard│  │
│  │  │                                                   │   │
│  │  ├── HTTPRoute (sklearn-iris)                      │   │
│  │  ├── HTTPRoute (sklearn-iris-predictor)            │   │
│  │  │                                                   │   │
│  │  └── ClusterIP Service (sklearn-iris-predictor:80)  │   │
│  │                                                      │   │
│  │  ┌───────────────────────────────────────────────┐   │   │
│  │  │  Model Pod (sklearn-iris-predictor-*)       │   │   │
│  │  │  Ready: 1/1  |  Running                     │   │   │
│  │  └───────────────────────────────────────────────┘   │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  KServe Controller (kserve-controller-manager)      │   │
│  │  Reconciles InferenceService → creates raw K8s       │   │
│  │  resources + HTTPRoutes                             │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  KServe Models Web App (ClusterIP :80 → :5000)    │   │
│  │  Dashboard UI for managing InferenceServices         │   │
│  │  Detects deployment mode (Standard/RawDeployment)    │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

---

## ArgoCD Applications (Sync Order)

Applications are deployed in wave order to respect dependencies:

| Wave | Application | Namespace | Path | Purpose |
|------|-----------|----------|------|---------|
| 0 | `kserve-crd` | kserve | `kserve-crd/` | CRDs for KServe + Gateway API |
| 1 | `kserve` | kserve | `kserve/` | KServe controller, GatewayClass, Gateway, ConfigMap |
| 2 | `gateway-helm` | envoy-gateway-system | `gateway-helm/` | Envoy Gateway controller + EnvoyProxy |
| 4 | `kserve-models-web-app` | kserve | `kserve-model-web-app/deployment/` | Web UI dashboard |

---

## Component Relationship Diagram

```
kserve-crd/                          (Wave 0 — CRDs)
├── InferenceService CRD               (serving.kserve.io/v1beta1)
├── GatewayClass CRD                  (gateway.networking.k8s.io/v1)
├── EnvoyProxy CRD                    (gateway.envoyproxy.io/v1alpha1)
└── + other Gateway API CRDs           (HTTPRoute, GRPCRoute, etc.)

kserve/                              (Wave 1 — KServe Controller)
│
├── ClusterRole (kserve-controller-manager)
│   └── Permissions: InferenceService, ServingRuntime, ClusterServingRuntime, etc.
│
├── ServiceAccount (kserve-controller-manager)
│
├── Deployment (kserve-controller-manager)
│   └── Pod: kserve-controller-manager-*
│       └── Containers:
│           ├── kube-rbac-proxy      (metrics auth)
│           └── manager            (KServe reconciler)
│
├── Service (kserve-controller-manager-service)  :8443
├── Service (kserve-webhook-server-service)     :443
│
├── ConfigMap (inferenceservice-config)
│   └── ingress:
│       ├── kserveIngressGateway: kserve/kserve-ingress-gateway
│       ├── domain: 192.168.49.2.sslip.io
│       ├── domainTemplate: {{ .Name }}-{{ .Namespace }}.{{ .IngressDomain }}
│       ├── disableIngressCreation: false     ← creates HTTPRoute automatically
│       └── urlScheme: http
│
├── GatewayClass (envoy)
│   ├── spec.controllerName: gateway.envoyproxy.io/gatewayclass-controller
│   └── spec.parametersRef → envoy-gateway-system/envoy-proxy
│
├── Gateway (kserve-ingress-gateway) [namespace: kserve]
│   ├── spec.gatewayClassName: envoy
│   ├── spec.listeners[http]: port 80
│   ├── spec.listeners[https]: port 443, tls.mode=Terminate
│   ├── spec.infrastructure.labels: serving.kserve.io/gateway=kserve-ingress-gateway
│   └── metadata.annotations: gateway.envoyproxy.io/service-type=NodePort
│
└── Secret (my-secret)           ← TLS cert for HTTPS listener
```

---

## Envoy Gateway Components

```
gateway-helm/                        (Wave 2 — Envoy Gateway)
│
├── EnvoyGateway ConfigMap (envoy-gateway-config)
│   └── data.envoy-gateway.yaml:
│       ├── provider.type: Kubernetes
│       ├── gateway.controllerName: gateway.envoyproxy.io/gatewayclass-controller
│       └── logging.level.default: info
│
├── EnvoyProxy (envoy-proxy) [namespace: envoy-gateway-system]
│   ├── spec.provider.type: Kubernetes
│   └── spec.provider.kubernetes.envoyService.type: NodePort  ← key for Minikube
│
├── Deployment (envoy-gateway)
│   └── Pod: envoy-gateway-*
│       └── Container: envoy-gateway:v1.7.0
│           └── Runs: GatewayClass controller + Infra reconciler + xDS server
│
└── Envoy Proxy Fleet (managed, created by infra reconciler)
    │
    ├── Deployment (envoy-kserve-kserve-ingress-gateway-*)
    │   └── Pod: envoy-kserve-kserve-ingress-gateway-*-*
    │       ├── Container: envoy (envoy:distroless-v1.37.0)     ← data plane
    │       └── Container: shutdown-manager
    │
    └── Service (envoy-kserve-kserve-ingress-gateway-*)  [NodePort]
        ├── type: NodePort  (externalTrafficPolicy: Local)
        ├── ports: HTTP 80→30757, HTTPS 443→31481
        ├── selector: gateway.envoyproxy.io/owning-gateway-name=kserve-ingress-gateway
        └── ownerReferences: GatewayClass (envoy)

  ┌──────────────────────────────────────────────────────────────┐
  │  Traffic Flow: NodePort → Envoy Proxy Pod → InferenceService   │
  └──────────────────────────────────────────────────────────────┘
```

---

## InferenceService & Traffic Flow (Standard/RawDeployment Mode)

```
Client Request
  │
  │ http://<node-ip>:30757
  │ Host: sklearn-iris-kserve-test.192.168.49.2.sslip.io
  │
  ▼
Minikube Node Port (:30757)
  │
  ▼
Envoy Proxy Pod (envoy-kserve-kserve-ingress-gateway-*-*)
  │
  ├── xDS: receives Listener config from Envoy Gateway Controller
  └── Routes based on Host header
       │
       ▼
  HTTPRoute (kserve-test/sklearn-iris)
    ├── parentRef: kserve/kserve-ingress-gateway
    ├── hostnames: [sklearn-iris-kserve-test.192.168.49.2.sslip.io]
    └── rules: forward to backend
       │
       ▼
  HTTPRoute (kserve-test/sklearn-iris-predictor)
    └── backendRef: sklearn-iris-predictor.kserve-test.svc.cluster.local:80
       │
       ▼
  ClusterIP Service (sklearn-iris-predictor)  [kserve-test]
    ├── selector: serving.kserve.io/inferenceservice-original-name=sklearn-iris
    └── targetPort: 80
       │
       ▼
  Model Pod (sklearn-iris-predictor-*-*)
    └── Port 80: sklearnserver listening for /v1/models/<name>:predict
```

---

## KServe Models Web App

```
kserve-model-web-app/deployment/      (Wave 4)
│
├── ServiceAccount (kserve-models-web-app) [kserve]
│
├── ClusterRole (kserve-models-web-app-cluster-role)
│   ├── serving.kserve.io: inferenceservices (CRUD + watch)
│   ├── serving.knative.dev: services, routes, configurations, revisions (read)
│   └── core: namespaces, pods, pods/log, events (read)
│
├── ClusterRoleBinding
│
├── Deployment (kserve-models-web-app)
│   └── Pod: kserve-models-web-app-*
│       ├── image: daonguyen24/kserve-models-web-app:v0.15.1
│       ├── port: 5000
│       └── env:
│           ├── APP_PREFIX: /
│           ├── APP_VERSION: v1beta1
│           ├── APP_DISABLE_AUTH: True
│           └── APP_SECURE_COOKIES: False
│
└── Service (kserve-models-web-app) [kserve]
    ├── type: ClusterIP
    └── port: 80 → targetPort: 5000
```

### Deployment Mode Detection (Frontend Fix)

The web app detects how an InferenceService was deployed:

```typescript
// server-info.component.ts — fixed in v0.15.1
getDeploymentMode(svc):
  ├── isModelMeshDeployment()  → annotation "serving.kserve.io/deploymentMode" = "ModelMesh"
  ├── isRawDeployment()        → annotation "serving.kserve.io/deploymentMode" = "Standard"
  │                              OR status.deploymentMode = "Standard"
  │                              OR annotation "serving.kubeflow.org/raw" = "true"
  └── else                     → "Serverless" (Knative Revision-based)
```

**Why this matters:** In `Standard` (RawDeployment) mode, there are **no Knative Revisions** — only raw K8s Deployments, Services, and HTTPRoutes. The web app must use `getRawDeploymentObjects()` instead of trying to fetch Knative Revision/Configuration/Route.

---

## Key Configuration Values

### `kserve/values.yaml`

| Key | Value | Note |
|-----|-------|------|
| `controller.deploymentMode` | `Standard` | RawDeployment (not Knative Serverless) |
| `gateway.domain` | `192.168.49.2.sslip.io` | Resolvable in Minikube via sslip.io |
| `gateway.disableIngressCreation` | `false` | KServe creates HTTPRoute automatically |
| `gateway.ingressGateway.enableGatewayApi` | `true` | Use Gateway API, not Ingress |
| `gateway.ingressGateway.kserveGateway` | `kserve/kserve-ingress-gateway` | Points to the Gateway resource |

### `gateway-helm/templates/envoy-proxy.yaml`

```yaml
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyService:
        type: NodePort        # Critical for Minikube (no cloud LB)
```

### `kserve/templates/gatewayclass.yaml`

```yaml
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  parametersRef:
    group: gateway.envoyproxy.io
    kind: EnvoyProxy
    name: envoy-proxy
    namespace: envoy-gateway-system
```

The `parametersRef` links the GatewayClass to the EnvoyProxy, which tells Envoy Gateway to create `NodePort` services instead of `LoadBalancer`.

---

## Quickstart: Test Inference

```bash
# 1. Deploy the model
kubectl apply -f quickstart/iris.yaml

# 2. Wait for ready
kubectl get inferenceservice -n kserve-test

# 3. Port-forward to Envoy Gateway
kubectl port-forward -n envoy-gateway-system \
  svc/envoy-kserve-kserve-ingress-gateway-deaaa49b 8082:80

# 4. Test inference (in another terminal)
curl -H "Host: sklearn-iris-kserve-test.192.168.49.2.sslip.io" \
     -H "Content-Type: application/json" \
     "http://localhost:8082/v1/models/sklearn-iris:predict" \
     -d '{"instances": [[5.1, 3.5, 1.4, 0.2], [7.0, 3.2, 4.7, 1.4], [6.3, 3.3, 6.0, 2.5]]}'

# Expected: {"predictions": [0, 1, 2]}
# 0 = Setosa, 1 = Versicolor, 2 = Virginica
```

Or use the convenience script:
```bash
bash quickstart/test-inference-gateway.sh
```

---

## Troubleshooting

### Gateway `PROGRAMMED: False` — `AddressNotAssigned`

Envoy Gateway can't assign an address because the managed Service is `LoadBalancer` but there's no cloud LB.

```bash
# Check service type
kubectl get svc -n envoy-gateway-system

# Should show NodePort, not LoadBalancer. If LoadBalancer:
# → Verify EnvoyProxy has spec.provider.kubernetes.envoyService.type: NodePort
# → Verify GatewayClass has parametersRef → EnvoyProxy
# → Restart Envoy Gateway: kubectl rollout restart deployment/envoy-gateway -n envoy-gateway-system
```

### InferenceService detail screen shows 404 (revisions/undefined)

The web app tried to fetch Knative Revisions, which don't exist in `Standard` mode. Fixed in image `v0.15.1`.

### Inference returns 404 via Gateway

1. Verify HTTPRoute is `Accepted` and `ResolvedRefs: True`:
   ```bash
   kubectl get httproute -n kserve-test -o yaml | grep -A5 conditions
   ```
2. Check the `Host` header matches the HTTPRoute hostname exactly.

### Model pod not starting

Check pod events:
```bash
kubectl describe pod -n kserve-test sklearn-iris-predictor-*
kubectl logs -n kserve-test sklearn-iris-predictor-* storage-initializer
```

Common issue: Storage initializer can't download from `gs://` bucket. Update `storageUri` in `quickstart/iris.yaml` to point to a reachable URI.

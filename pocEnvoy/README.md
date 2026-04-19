# pocEnvoy

Minimal Envoy Gateway setup information for custom cluster bootstrapping.

This folder is intentionally kept minimal for a common official Envoy Gateway install with values overrides.

## 1) Install Gateway API CRDs

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/latest/download/standard-install.yaml
```

## 2) Install official Envoy Gateway Helm chart

```bash
helm repo add envoyproxy https://helm.envoyproxy.io
helm repo update

helm upgrade --install envoy-gateway envoyproxy/gateway-helm \
  --version v1.7.1 \
  -n envoy-gateway-system --create-namespace \
  -f values.yaml
```

## 3) values.yaml in this folder

The local values.yaml is pre-configured for:
- gateway.name: envoy-gateway
- gateway.className: envoy-gateway-class
- listeners: http 80, https 443 (TLS terminate), tcp 9000
- gatewayClass.controllerName: gateway.envoyproxy.io
- controller.image: envoyproxy/envoy-gateway:main (override to pinned release)

## 4) Deploy your workloads and routes

After install, create your backend Service(s) and HTTPRoute/TCPRoute objects.

## 5) Verify status

kubectl -n envoy-gateway-system get deployment,service
kubectl get gateway,gatewayclass,httproute,tcproute --all-namespaces
kubectl logs -n envoy-gateway-system -l app.kubernetes.io/name=envoy-gateway



# helloWorld

Minimal Hello World app to test Envoy Gateway traffic routing.

## Install

```bash
helm upgrade --install hello-world ./helloWorld -n envoy-gateway-system --create-namespace
```

## What this deploys

- Deployment `hello-world` (`hashicorp/http-echo:0.2.3`, returns text `pong`)
- Service `hello-world:8080`
- HTTPRoute `hello-world-route` attached to `Gateway` named `envoy-gateway` in namespace `envoy-gateway-system`

## Test

1. Wait for pods:

```bash
kubectl -n envoy-gateway-system get pods
```

2. Ensure route is accepted:

```bash
kubectl get httproute -n envoy-gateway-system
```

3. Hit via Envoy Gateway data plane (port depends on installation, e.g. 18002):

```bash
curl -v http://<envoy-gateway-address>:<http-port>/
```

On successful path you should see `pong`.

If you use `kubectl port-forward`:

```bash
kubectl port-forward -n envoy-gateway-system svc/envoy-gateway 8080:18002
curl http://127.0.0.1:8080/
```

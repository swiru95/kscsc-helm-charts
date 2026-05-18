# metallb

MetalLB load-balancer for bare-metal Kubernetes (L2 mode).

Currently running: **v0.14.3** (deployed outside Helm — `metallb-system` namespace, 132d).

## Install

```bash
helm repo add metallb https://metallb.github.io/metallb
helm repo update

helm upgrade --install metallb metallb/metallb \
  --version 0.14.3 \
  -n metallb-system --create-namespace \
  -f values.yaml

# Apply L2 address pool after controller is ready
helm upgrade --install metallb-config ./metallb \
  -n metallb-system
```

## L2 address pool

`192.168.95.50–192.168.95.60` is the current allocation:

| IP | Service |
|---|---|
| 192.168.95.50 | nginx ingress (`ingress-nginx`) |
| 192.168.95.51 | Envoy Gateway (`envoy-gateway-system`) |

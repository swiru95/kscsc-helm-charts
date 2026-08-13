# CoreDNS Custom — In-Cluster DNS for kscsc.local

Creates the K3s `coredns-custom` ConfigMap so that `*.kscsc.local` resolves to the **Envoy Gateway's MetalLB address** inside the cluster. This keeps all traffic (including ACME HTTP-01 challenges) on the cluster's own ingress path.

Optionally reconciles the CoreDNS Deployment so the GPU toleration is restored after k3s re-applies its built-in CoreDNS addon on host restart.

## How it works

```
Pod DNS query ──▶ CoreDNS ──(kscsc.local server block)──▶ hosts plugin ──▶ ingress ClusterIP
```

K3s CoreDNS imports `coredns-custom` ConfigMap entries:
- `*.override` files are included in the main `.:53` server block
- `*.server` files are added as separate server blocks

This chart creates a `kscsc-local.server` entry — a dedicated server block for `kscsc.local:53`.

## Prerequisites

- K3s (CoreDNS configured to import `/etc/coredns/custom/*.server`)
- Envoy Gateway deployed, with a MetalLB address assigned

## Quick Start

```bash
cd coreDNS
helm install coredns-custom . -n kube-system
```

## Adding a new host

Add the hostname under the matching key in `values.yaml`. `envoy` entries
resolve to `envoyIP`; `static` entries carry their own IP
and are for hosts that live outside the cluster:

```yaml
hosts:
  envoy:
    - ca.kscsc.local
    - myapp.kscsc.local        # <-- new, via Envoy Gateway
  static:
    - ip: 192.168.95.201
      name: llama.kscsc.local  # <-- new, external host
```

Then upgrade:

```bash
helm upgrade coredns-custom . -n kube-system
```

The reconcile CronJob will keep the toleration in place even after the host or k3s restarts.

## Configuration

| Parameter | Description | Default |
|---|---|---|
| `zone` | DNS zone for the server block | `kscsc.local` |
| `envoyIP` | MetalLB address of the Envoy Gateway service | `192.168.95.51` |
| `hosts.envoy` | Hostnames resolving to `envoyIP` | See values.yaml |
| `hosts.static` | `{ip, name}` pairs for hosts outside the cluster | See values.yaml |
| `patch.enabled` | Run a CronJob to restore the GPU toleration when k3s overwrites CoreDNS | `true` |
| `patch.schedule` | How often the reconcile job checks CoreDNS | `*/2 * * * *` |
| `patch.image.*` | Container image used by the reconcile job | `bitnami/kubectl:latest` |
| `patch.toleration.key` | Taint key to tolerate | `nvidia.com/gpu` |
| `patch.toleration.operator` | Toleration operator | `Exists` |
| `patch.toleration.effect` | Taint effect | `NoSchedule` |

## Finding the ingress ClusterIP

```bash
kubectl -n envoy-gateway-system get svc -l gateway.envoyproxy.io/owning-gateway-name=envoy-gateway -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}'
```

## Uninstalling

```bash
helm uninstall coredns-custom -n kube-system
```

> **Note:** Uninstalling removes the `coredns-custom` ConfigMap. CoreDNS will stop resolving `*.kscsc.local` after its next reload (~30s) or restart.

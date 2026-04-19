# CoreDNS Custom — In-Cluster DNS for kscsc.local

Creates the K3s `coredns-custom` ConfigMap so that `*.kscsc.local` resolves to the **nginx ingress controller's ClusterIP** inside the cluster. This keeps all traffic (including ACME HTTP-01 challenges) entirely in-cluster.

Optionally patches the CoreDNS Deployment to add a GPU toleration and restarts it.

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
- nginx ingress controller deployed

## Quick Start

```bash
cd coreDNS
helm install coredns-custom . -n kube-system
```

## Adding a new host

Add the hostname to the `hosts` list in `values.yaml`:

```yaml
hosts:
  - ca.kscsc.local
  - myapp.kscsc.local    # <-- new
```

Then upgrade:

```bash
helm upgrade coredns-custom . -n kube-system
```

The post-upgrade hook will restart CoreDNS automatically.

## Configuration

| Parameter | Description | Default |
|---|---|---|
| `zone` | DNS zone for the server block | `kscsc.local` |
| `ingressIP` | ClusterIP of the ingress controller | `10.43.79.66` |
| `hosts` | List of hostnames to resolve | See values.yaml |
| `patch.enabled` | Run a Job to add GPU toleration + restart CoreDNS | `true` |
| `patch.toleration.key` | Taint key to tolerate | `nvidia.com/gpu` |
| `patch.toleration.operator` | Toleration operator | `Exists` |
| `patch.toleration.effect` | Taint effect | `NoSchedule` |

## Finding the ingress ClusterIP

```bash
kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.spec.clusterIP}'
```

## Uninstalling

```bash
helm uninstall coredns-custom -n kube-system
```

> **Note:** Uninstalling removes the `coredns-custom` ConfigMap. CoreDNS will stop resolving `*.kscsc.local` after its next reload (~30s) or restart.

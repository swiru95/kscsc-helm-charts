# CoreDNS Custom — In-Cluster DNS for kscsc.local

Creates the K3s `coredns-custom` ConfigMap so that `*.kscsc.local` resolves to the **Envoy Gateway's MetalLB address** inside the cluster. This keeps all traffic (including ACME HTTP-01 challenges) on the cluster's own ingress path.

Optionally reconciles the CoreDNS Deployment so the GPU toleration is restored **and CoreDNS is pinned to the management node** after k3s re-applies its built-in CoreDNS addon on host restart.

It can also expose CoreDNS on the LAN via a MetalLB LoadBalancer (`192.168.95.53`) and restrict which source IPs may enumerate the internal Kubernetes zones.

## How it works

```
Pod DNS query ──▶ CoreDNS ──(kscsc.local server block)──▶ hosts plugin ──▶ ingress ClusterIP
```

K3s CoreDNS imports `coredns-custom` ConfigMap entries:
- `*.override` files are included in the main `.:53` server block
- `*.server` files are added as separate server blocks

This chart creates a `kscsc-local.server` entry — a dedicated server block for `kscsc.local:53` — plus `kscsc-local.db`, an SOA-only zone that answers unknown `kscsc.local` names with an authoritative NXDOMAIN instead of forwarding them upstream.

## LAN DNS & access control

When `lanService.enabled` is true, a LoadBalancer Service (`coredns-custom-lan`) exposes CoreDNS on the LAN at `lanService.loadBalancerIP` (`192.168.95.53`). Because `externalTrafficPolicy` is `Local`, the service only forwards to the node running the CoreDNS pod and preserves the real client source IP — which is what makes the ACL below possible.

By default CoreDNS answers *every* zone to anyone who can reach it, including `cluster.local`. Pointing LAN clients at it would let them enumerate internal service names (the returned cluster IPs are unreachable from the LAN, but the names are exposed). To stop that without breaking the cluster, the chart adds a **zone-scoped `acl` rule** via a `*.override` file:

- The rule is scoped to `cluster.local` and the reverse zones of the pod and service CIDRs (`42.10.in-addr.arpa`, `43.10.in-addr.arpa`), so it only affects those zones. The external `forward .`, ordinary reverse lookups and the separate `kscsc.local` server block stay fully open, so LAN clients can still resolve `*.kscsc.local` **and** outside names.
- The whole LAN subnet (`192.168.95.0/24`) is blocked from those zones; the pod CIDR and the three node IPs stay allowed. The node IPs must be listed because nodes and LAN clients share the subnet, and rules match first-wins with the `allow` lines rendered before `block`, so they keep working.

Net effect for a LAN client: `*.kscsc.local` and external names resolve, but `*.cluster.local` and PTR lookups for pod/service IPs return `REFUSED`.

To point clients at it, the cleanest option is a **conditional forward** on the router (send only `kscsc.local` to `192.168.95.53` and leave everything else as-is). You can also set `.53` as a client's DNS server outright — it recurses for outside names too.

> **Note:** CoreDNS currently runs as a single pod. The `patch.nodeSelector` pins it to the management node so the LAN DNS endpoint is stable and survives the GPU node going down; while that pod is restarting, LAN DNS is briefly unavailable too.

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
| `negativeTTL` | How long clients cache "does not exist" for an unlisted name | `60` |
| `hosts.envoy` | Hostnames resolving to `envoyIP` | See values.yaml |
| `hosts.static` | `{ip, name}` pairs for hosts outside the cluster | See values.yaml |
| `lanService.enabled` | Expose CoreDNS on the LAN via a MetalLB LoadBalancer | `true` |
| `lanService.loadBalancerIP` | LAN address for DNS clients | `192.168.95.53` |
| `lanService.externalTrafficPolicy` | `Local` preserves client IPs | `Local` |
| `patch.enabled` | Run a CronJob to restore the GPU toleration when k3s overwrites CoreDNS | `true` |
| `patch.schedule` | How often the reconcile job checks CoreDNS | `*/2 * * * *` |
| `patch.image.*` | Container image used by the reconcile job (needs `sh` + `grep` + `kubectl`) | `alpine/k8s:1.36.4` |
| `patch.toleration.key` | Taint key to tolerate | `nvidia.com/gpu` |
| `patch.toleration.operator` | Toleration operator | `Exists` |
| `patch.toleration.effect` | Taint effect | `NoSchedule` |
| `patch.nodeSelector` | Labels merged into the CoreDNS nodeSelector (keeps the LAN DNS endpoint on the management node); `null` disables pinning | `kubernetes.io/hostname: k3subuntumaster` |
| `lanService.acl.enabled` | Add the zone-scoped ACL so the LAN can't enumerate internal zones | `true` |
| `lanService.acl.zones` | Internal zones to restrict for the LAN | `cluster.local`, `42.10.in-addr.arpa`, `43.10.in-addr.arpa` |
| `lanService.acl.blockedSubnet` | LAN subnet blocked from those zones | `192.168.95.0/24` |
| `lanService.acl.allowed` | Source networks still allowed to query the zones (must include the pod CIDR and the node IPs) | `10.42.0.0/16` + the three node IPs |

## Finding the ingress ClusterIP

```bash
kubectl -n envoy-gateway-system get svc -l gateway.envoyproxy.io/owning-gateway-name=envoy-gateway -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}'
```

## Uninstalling

```bash
helm uninstall coredns-custom -n kube-system
```

> **Note:** Uninstalling removes the `coredns-custom` ConfigMap. CoreDNS will stop resolving `*.kscsc.local` after its next reload (~30s) or restart.

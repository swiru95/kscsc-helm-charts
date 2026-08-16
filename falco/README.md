# falco

Envoy Gateway routing for the Falco runtime-security stack.

Falco watches syscalls on every node and raises an event when something matches a
rule — a shell opened inside a container, a write under `/etc`, a process reading
`/etc/shadow`, an unexpected outbound connection. Falcosidekick fans those events
out, and the Falcosidekick UI is the console you actually look at.

## What lives where

This chart contains **only the HTTPRoutes**. Falco, its driver DaemonSet,
Falcosidekick and the UI all come from the upstream `falcosecurity/falco` chart.

The split exists because the upstream chart can only emit an `Ingress`, and this
cluster has no Ingress controller — Envoy Gateway terminates TLS at
`192.168.95.51` and routes by Gateway API. The same split is used by `step-ca`.

| Piece | Chart | Values |
| --- | --- | --- |
| Falco + Sidekick + UI | `falcosecurity/falco` | `falco__falco.yaml` |
| HTTPRoutes | this chart | `falco__falco-gw.yaml` |

## Installation

```sh
helm repo add falcosecurity https://falcosecurity.github.io/charts --force-update
helm repo update falcosecurity

# 1. The stack itself
helm upgrade --install falco falcosecurity/falco -n falco --create-namespace \
  -f "$V/falco__falco.yaml"

# 2. The routes — after the release above, so the backend Service exists
helm upgrade --install falco-gw "$CHARTS/falco" -n falco \
  -f "$V/falco__falco-gw.yaml"
```

Then browse to <https://falco.kscsc.local>.

## Prerequisites outside this chart

Both are already committed, but they are easy to forget when adding the next host:

- **DNS** — `falco.kscsc.local` must be in `coreDNS/values.yaml` under
  `hosts.envoy`, or the name will not resolve to the gateway.
- **TLS SAN** — `falco.kscsc.local` must be in `certificate.dnsNames` in
  `envoy-gateway-system__envoy-resources.yaml`. The gateway serves one
  cert for all hosts; a name missing from the SAN list still routes, but every
  browser throws a certificate warning.

## Access

The console is guarded by **basic auth only** — the Envoy route does not
authenticate. Credentials come from `falcosidekick.webui.user` in
`falco__falco.yaml`, in `login:password` form. Rotate by editing that value and
re-running the upgrade.

## Drivers

`driver.kind` is `auto`, so each node picks for itself: `modern_ebpf` where the
kernel exposes CO-RE BTF, otherwise the kernel module. The two workers run
6.8.0-generic and take the eBPF path; the control-plane node runs a `-pve`
kernel, which is why the choice is left per-node rather than pinned.

Check what each node actually chose:

```sh
kubectl -n falco logs -l app.kubernetes.io/name=falco -c falco --tail=20 | grep -i driver
```

## Scheduling

The DaemonSet tolerates the control-plane taint and the `nvidia.com/gpu` taint on
the GPU node. Without those tolerations Falco is silently skipped on those nodes
— it does not error, you simply stop seeing events from them, which is the worst
possible failure mode for a security tool.

Confirm it is on all three:

```sh
kubectl -n falco get pods -o wide
```

## Testing that it works

Trigger a rule on purpose and watch it land in the UI:

```sh
kubectl run falco-test --rm -it --image=busybox --restart=Never -- sh -c 'cat /etc/shadow'
```

That fires `Read sensitive file untrusted`. If nothing shows up, check the
Sidekick connection first:

```sh
kubectl -n falco logs -l app.kubernetes.io/name=falcosidekick --tail=50
```

## Storage

The UI's event store is Redis backed by a 5Gi local-path PVC with a 7-day TTL.
local-path is node-local and RWO, so the UI pod is effectively pinned to whichever
node first scheduled it. That is fine at one replica; do not scale the UI up
without moving Redis to shared storage first.

# splunk-gw

Envoy Gateway routing for the Splunk stack.

Splunk watches logs from everywhere and lets you search, alert, and visualise them.
This chart provides the Gateway API routes so the cluster's Envoy Gateway can
reach Splunk's web UI (HTTPS) and accept forwarded logs (TCP forwarder 9997,
HEC 8088).

## What lives where

| Piece | Chart | Values |
| --- | --- | --- |
| Splunk server + PVCs | `splunk` (local) | `splunk__splunk.yaml` |
| HTTPRoutes / TCPRoutes | this chart | `splunk__splunk-gw.yaml` |

The split exists because the upstream chart can only emit an `Ingress`, and this
cluster has no Ingress controller — Envoy Gateway terminates TLS at
`192.168.95.51` and routes by Gateway API. The same split is used by `step-ca`
and `openvas`.

## Installation

```sh
# 1. The Splunk server itself (with PVCs)
helm upgrade --install splunk "$CHARTS/splunk" -n splunk --create-namespace \
  -f "$V/splunk__splunk.yaml"

# 2. The routes — after the release above, so the backend Service exists
helm upgrade --install splunk-gw "$CHARTS/splunk-gw" -n splunk \
  -f "$V/splunk__splunk-gw.yaml"
```

Then browse to <https://splunk.kscsc.local>.

## Prerequisites outside this chart

Both are already committed, but they are easy to forget when adding the next host:

- **DNS** — `splunk.kscsc.local` must be in `coreDNS/values.yaml` under
  `hosts.envoy`, or the name will not resolve to the gateway.
- **TLS SAN** — `splunk.kscsc.local` must be in `certificate.dnsNames` in
  `envoy-gateway-system__envoy-resources.yaml`. The gateway serves one
  cert for all hosts; a name missing from the SAN list still routes, but every
  browser throws a certificate warning.

## Access

The web UI is guarded by **basic auth** — the credentials are the Splunk admin
password set via `splunk.password` or `splunk.existingSecret` in the values file.
Browse to <https://splunk.kscsc.local> and log in with `admin:<password>`.

## Ports

| Port | Protocol | Purpose | Route |
| --- | --- | --- | --- |
| 443 → 8000 | HTTPS | Web UI | HTTPRoute |
| 9997 | TCP | Splunk forwarder | TCPRoute |
| 8088 | TCP | HEC (HTTP Event Collector) | TCPRoute |

The forwarder and HEC ports are exposed as raw TCP through the Gateway — no TLS
termination at the Gateway layer. Clients connecting to these ports must speak
the Splunk protocol directly.

## Storage

Splunk uses two PVCs:

- **data** (`/opt/splunk/var`) — indexes, buckets, metadata. Default 20Gi.
- **etc** (`/opt/splunk/etc`) — configuration, certificates, secrets. Default 5Gi.

Both use the `local-path` StorageClass. Adjust sizes in `splunk__splunk.yaml`
under `persistence.size` and `persistence.etcSize`.

## Testing that it works

Send a test event to the HEC port and search for it:

```sh
curl -k -u admin:<password> \
  -H "Authorization: Splunk <token>" \
  -d '"Hello from Helm"' \
  https://splunk.kscsc.local:8088/services/collector
```

Or trigger a Falco event and watch it land in Splunk (see Falco configuration below).

## Falco integration

Falco can ship events to Splunk via HEC. Configure the Falcosidekick Splunk
output in `falco__falco.yaml` — see the Falco chart README for details.

## Scheduling

The Deployment tolerates the `nvidia.com/gpu` taint so it can land on the GPU
node if needed. By default it has no nodeSelector, so the scheduler picks
any available node. Override with `nodeSelector` in the values file.

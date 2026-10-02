# falco

Envoy Gateway routing for the Falco runtime-security stack.

Falco watches syscalls on every node and raises an event when something matches a
rule — a shell opened inside a container, a write under `/etc`, a process reading
`/etc/shadow`, an unexpected outbound connection. Falcosidekick fans those events
out, and the Falcosidekick UI is the console you actually look at.

## What lives where

This chart contains **the HTTPRoutes and optional NetworkPolicies**. Falco, its
driver DaemonSet, Falcosidekick and the UI all come from the upstream
`falcosecurity/falco` chart (running our forked Sidekick and UI images).

The split exists because the upstream chart can only emit an `Ingress`, and this
cluster has no Ingress controller — Envoy Gateway terminates TLS at
`192.168.95.51` and routes by Gateway API. The same split is used by `step-ca`.

| Piece | Chart | Values |
| --- | --- | --- |
| Falco + Sidekick + UI | `falcosecurity/falco` | `falco__falco.yaml` |
| HTTPRoutes, NetworkPolicies | this chart | `falco__falco-gw.yaml` |

`values.example.yaml` shows the upstream release's values with placeholders.

## Installation

```sh
helm repo add falcosecurity https://falcosecurity.github.io/charts --force-update
helm repo update falcosecurity

# 0. The two Secrets from "Access" below (falco-ui-auth, falco-redis)

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

The stack runs the forked images `ghcr.io/swiru95/falcosidekick` and
`ghcr.io/swiru95/falcosidekick-ui`. Their tags are commit SHAs: replace the
`TAG_SET_AT_DEPLOY` placeholder in the values before upgrading.

Basic auth is gone. Two hand-made Secrets carry everything sensitive; create
both **before** `helm upgrade`, or the pods sit in `CreateContainerConfigError`.

### SSO (Entra ID)

Browsers sign in through OIDC against Entra ID (tenant
`1b3ec069-f45f-4b09-bb2d-5d7806950a5f`, v2.0 issuer). Register a **web** app with
redirect URI `https://falco.kscsc.local/api/v1/auth/oidc/callback`, create a client
secret, define the app role `Falco.Viewer` and assign it to the people allowed in.
Entra puts app roles in the `roles` claim, which the UI checks
(`OIDC_GROUPS_CLAIM=roles`, `OIDC_ALLOWED_GROUPS=Falco.Viewer`); the display name
comes from `preferred_username`. Anyone without the role is refused after login.

### Ingestion auth (Sidekick -> UI)

Sidekick no longer posts anonymously. It mounts a projected ServiceAccount token
(audience `falcosidekick-ui`, 1h, rotated by kubelet) and sends it as
`Authorization: Bearer`. The UI (`INGEST_AUTH=oidc`) validates it against the
cluster's own issuer `https://kubernetes.default.svc.cluster.local`, accepts only
subject `system:serviceaccount:falco:falco-falcosidekick` (the Sidekick pod's
ServiceAccount), and fetches the signing keys using its own automounted CA and
token (`/var/run/secrets/kubernetes.io/serviceaccount/{ca.crt,token}`). No extra
RBAC is needed: `system:service-account-issuer-discovery` is bound to all
ServiceAccounts by default. The Sidekick -> UI hop is still plain HTTP inside the
cluster; the NetworkPolicies below limit who can sniff or reach it.

### Redis password

Redis now requires a password. The upstream chart only wires the password anywhere
when `webui.redis.password` is non-empty, so the values carry a dummy
(`set-via-existing-secret`) and the real one comes from the Secrets, which win in
`envFrom` order. Three consumers need it:

| Consumer | Source | Key |
| --- | --- | --- |
| Redis StatefulSet (`redis-stack`) | Secret `falco-redis` | `REDIS_ARGS` (`--requirepass <pw>`) |
| wait-redis init container | Secret `falco-ui-auth` | `REDIS_PASSWORD` |
| UI | Secret `falco-ui-auth` | `FALCOSIDEKICK_UI_REDIS_PASSWORD` |

### Create the Secrets

Fill the three placeholders (Entra application/client ID, client secret) and run
once. The Redis password is generated hex so it is safe inside `REDIS_ARGS`.

```sh
export KUBECONFIG=~/.kube/kscsc-new.yaml
ENTRA_CLIENT_ID='<application-client-id>'
ENTRA_CLIENT_SECRET='<client-secret-value>'
REDIS_PW="$(openssl rand -hex 24)"
SA=/var/run/secrets/kubernetes.io/serviceaccount

kubectl get ns falco >/dev/null 2>&1 || kubectl create ns falco

kubectl -n falco create secret generic falco-redis \
  --from-literal=REDIS_ARGS="--requirepass ${REDIS_PW}" \
  --from-literal=REDIS_PASSWORD="${REDIS_PW}" &&
kubectl -n falco create secret generic falco-ui-auth \
  --from-literal=REDIS_PASSWORD="${REDIS_PW}" \
  --from-literal=FALCOSIDEKICK_UI_REDIS_PASSWORD="${REDIS_PW}" \
  --from-literal=FALCOSIDEKICK_UI_AUTH_MODE=oidc \
  --from-literal=FALCOSIDEKICK_UI_OIDC_ISSUER='https://login.microsoftonline.com/1b3ec069-f45f-4b09-bb2d-5d7806950a5f/v2.0' \
  --from-literal=FALCOSIDEKICK_UI_OIDC_CLIENT_ID="${ENTRA_CLIENT_ID}" \
  --from-literal=FALCOSIDEKICK_UI_OIDC_CLIENT_SECRET="${ENTRA_CLIENT_SECRET}" \
  --from-literal=FALCOSIDEKICK_UI_OIDC_REDIRECT_URL='https://falco.kscsc.local/api/v1/auth/oidc/callback' \
  --from-literal=FALCOSIDEKICK_UI_OIDC_SCOPES='openid,profile,email' \
  --from-literal=FALCOSIDEKICK_UI_OIDC_USERNAME_CLAIM=preferred_username \
  --from-literal=FALCOSIDEKICK_UI_OIDC_GROUPS_CLAIM=roles \
  --from-literal=FALCOSIDEKICK_UI_OIDC_ALLOWED_GROUPS=Falco.Viewer \
  --from-literal=FALCOSIDEKICK_UI_INGEST_AUTH=oidc \
  --from-literal=FALCOSIDEKICK_UI_INGEST_OIDC_ISSUER='https://kubernetes.default.svc.cluster.local' \
  --from-literal=FALCOSIDEKICK_UI_INGEST_OIDC_AUDIENCE=falcosidekick-ui \
  --from-literal=FALCOSIDEKICK_UI_INGEST_OIDC_ALLOWED_SUBJECTS='system:serviceaccount:falco:falco-falcosidekick' \
  --from-literal=FALCOSIDEKICK_UI_INGEST_OIDC_CA_FILE="${SA}/ca.crt" \
  --from-literal=FALCOSIDEKICK_UI_INGEST_OIDC_JWKS_BEARER_FILE="${SA}/token"
```

Redis keeps its data on a PVC, so rotating the password later means updating both
Secrets and restarting the Redis StatefulSet and the UI together.

### NetworkPolicies

`networkPolicy.enabled: true` renders three ingress-only policies (egress stays
open: the UI needs Entra ID and the API server, Sidekick its outputs):

| Pod | Port | Allowed from |
| --- | --- | --- |
| Redis (`component=ui-redis`) | 6379 | UI pods (`component=ui`) only |
| UI (`component=ui`) | 2802 | Sidekick pods (`component=core`) and namespace `envoy-gateway-system` |
| Sidekick (`component=core`) | 2801 | Falco DaemonSet pods (`name=falco`) only |

Falco pods do not use host networking, so the pod selector matches them. k3s
enforces policies with its embedded kube-router controller. Kubelet probes come
from the node IP and kube-router lets node-local traffic through, but this is
the first thing to check after enabling: `kubectl -n falco get pods` must stay
`Ready` (UI probes `/api/v1/healthz` on 2802, Sidekick probes 2801, Redis is a TCP
probe on 6379). Also confirm events still arrive and the console loads.
Anything else that needs those ports (a Prometheus scrape, a debug pod) has to
be added to the policies.

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

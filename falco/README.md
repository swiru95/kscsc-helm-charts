# falco

Envoy Gateway routing for the Falco runtime-security stack.

Falco watches syscalls on every node and raises an event when something matches a
rule — a shell opened inside a container, a write under `/etc`, a process reading
`/etc/shadow`, an unexpected outbound connection. Falcosidekick fans those events
out, and the Falcosidekick UI is the console you actually look at.

## What lives where

This chart contains **the HTTPRoutes, optional NetworkPolicies and the UI's
auth-config Secret**. Falco, its
driver DaemonSet, Falcosidekick and the UI all come from the upstream
`falcosecurity/falco` chart (running our forked Sidekick and UI images).

The split exists because the upstream chart can only emit an `Ingress`, and this
cluster has no Ingress controller — Envoy Gateway terminates TLS at
`192.168.95.51` and routes by Gateway API. The same split is used by `step-ca`.

| Piece | Chart | Values |
| --- | --- | --- |
| Falco + Sidekick + UI | `falcosecurity/falco` | `falco__falco.yaml` |
| HTTPRoutes, NetworkPolicies, UI config Secret | this chart | `falco__falco-gw.yaml` |

`values.example.yaml` shows the upstream release's values with placeholders.

## Installation

```sh
helm repo add falcosecurity https://falcosecurity.github.io/charts --force-update
helm repo update falcosecurity

# 0. Create the namespace with autocert label (enables mTLS cert injection)
kubectl apply -f "$CONFIG/manifests/falco-namespace.yaml"

# 1. falco-gw: creates the falco-ui-auth config Secret the upstream release envFroms,
#    the routes and the NetworkPolicies
helm upgrade --install falco-gw "$CHARTS/falco" -n falco \
  -f "$V/falco__falco-gw.yaml"

# 2. The stack itself
helm upgrade --install falco falcosecurity/falco -n falco \
  -f "$V/falco__falco.yaml"
```

Order matters: the namespace must be labelled before Falco pods run (for autocert),
without `falco-ui-auth` the UI pod sits in `CreateContainerConfigError`, and the
route may exist before its backend Service does (that is harmless).

Then browse to <https://falco.kscsc.local>.

## Prerequisites outside this chart

Both are already committed, but they are easy to forget when adding the next host:

- **DNS** — `falco.kscsc.local` must be in `coreDNS/values.yaml` under
  `hosts.envoy`, or the name will not resolve to the gateway.
- **TLS SAN** — `falco.kscsc.local` must be in `certificate.dnsNames` in
  `envoy-gateway-system__envoy-resources.yaml`. The gateway serves one
  cert for all hosts; a name missing from the SAN list still routes, but every
  browser throws a certificate warning.
- **Namespace label for mTLS** — The `falco` namespace must be labelled
  `autocert.step.sm: enabled` so that Falco and Sidekick pods can opt into
  step-ca autocert. Create it with `config/manifests/falco-namespace.yaml`
  before any other Falco install.

## Access

The stack runs the forked images `ghcr.io/swiru95/falcosidekick` and
`ghcr.io/swiru95/falcosidekick-ui`. Their tags are commit SHAs: replace the
`TAG_SET_AT_DEPLOY` placeholder in the values before upgrading.

The setup is **secretless**: no passwords, no client secrets, no hand-made
Secrets. Authentication rests on three things:

### Falco → Sidekick mTLS via step-ca autocert

The Falco DaemonSet and Falcosidekick Deployment both carry
`autocert.step.sm/name: <dns-name>` annotations. The step-ca autocert controller
injects an init container (fetches initial certs) and a renewer sidecar into each
pod, writing:

- `/var/run/autocert.step.sm/site.crt` — leaf cert, 24-hour lifetime, rewritten
  in place on renewal
- `/var/run/autocert.step.sm/site.key` — TLS key
- `/var/run/autocert.step.sm/root.crt` — KSCSC root CA

Falco's `http_output` block configures the HTTPS endpoint with client certs;
Sidekick's `tlsserver` deploys as mTLS server. The server does not reload from
disk; instead, it checks cert file mtimes at most once every 30 seconds
(configurable, but 30s is appropriate for 24h certs) and reloads on change,
logging reloads and errors separately.

Sidekick's `allowedclientsans` list restricts client certificates by their SubjectAlternativeName (or Subject.CommonName): only Falco's cert passes. An empty list accepts any cert signed by the CA, so it must be set if you run other pods in the namespace.

Probes use the plain-HTTP port `http-notls: 2810` (path `/ping` with no auth),
while the secure port `:2801` stays for Falco only.

### Secrets and authentication

- **Browsers**: a public OIDC client with PKCE against Entra ID, gated by user
  assignment and the `Falco.Viewer` app role.
- **Sidekick -> UI ingestion**: a projected, short-lived ServiceAccount token.
- **Redis**: no password at all; only the UI pods can reach it (NetworkPolicy).

The UI's settings live in the Secret `falco-ui-auth`, rendered by this chart from
the `uiAuth:` values block (`tenantId`, `clientId`, claims, ingest settings). It
contains no secret material. It is a Secret instead of a ConfigMap only because
the upstream chart can only `envFrom` a Secret (`falcosidekick.webui.existingSecret`).
`tenantId` and `clientId` are identifiers, not credentials; the real ones are in
the private config repo.

### SSO (Entra ID, public client with PKCE)

Tenant `1b3ec069-f45f-4b09-bb2d-5d7806950a5f`, v2.0 issuer. In the app
registration:

1. **Authentication**: add the **Mobile and desktop applications** platform (this
   is what makes Entra treat it as a public client, so PKCE works without a
   secret) with redirect URI
   `https://falco.kscsc.local/api/v1/auth/oidc/callback`. Do not add a Web
   platform.
2. **Certificates & secrets**: create none.
3. **App roles**: define `Falco.Viewer` (allowed member type: users/groups).
4. **Enterprise application -> Properties**: **Assignment required = Yes**, then
   assign the people allowed in to the `Falco.Viewer` role.

Entra puts app roles in the `roles` claim, which the UI checks
(`OIDC_GROUPS_CLAIM=roles`, `OIDC_ALLOWED_GROUPS=Falco.Viewer`); the display name
comes from `preferred_username`. A public client is not a credential: anyone can
start a login, so the gate is Entra refusing unassigned users plus the UI refusing
tokens without the role.

### Ingestion auth (Sidekick -> UI)

Sidekick no longer posts anonymously. It mounts a projected ServiceAccount token
(audience `falcosidekick-ui`, 1h, rotated by kubelet) and sends it as
`Authorization: Bearer`. The UI (`INGEST_AUTH=oidc`) validates it against the
cluster's own issuer `https://kubernetes.default.svc.cluster.local`, accepts only
subject `system:serviceaccount:falco:falco-falcosidekick` (the Sidekick pod's
ServiceAccount), and fetches the signing keys using its own automounted CA and
token (`/var/run/secrets/kubernetes.io/serviceaccount/{ca.crt,token}`). No extra
RBAC is needed: `system:service-account-issuer-discovery` is bound to all
ServiceAccounts by default.

### Redis

Redis (`redis-stack`) runs **without a password**; the upstream values set
`webui.redis.password` to nothing, so no `requirepass`, `REDIS_ARGS` or
`REDIS_PASSWORD` is wired anywhere. Its only access control is the NetworkPolicy
below (port 6379 from UI pods only). It holds the event history, so enable the
policies (`networkPolicy.enabled: true`).

### Residual risks

- **Redis is unauthenticated.** If the NetworkPolicies are off or not enforced
  (CNI without policy support, a mistaken selector), any pod in the cluster can
  read and wipe the event store. Verify enforcement after every CNI change.
- **The ingest bearer travels over plain HTTP inside the cluster.** The token is
  audience-bound, short-lived and only accepted for one subject, but a pod able to
  sniff the Sidekick -> UI hop could replay it within its lifetime. The
  NetworkPolicies limit who can reach the UI port, not who can observe the node
  network.
- The public client has no secret to leak, but also nothing that stops someone
  from starting a login flow; protection depends entirely on Entra assignment and
  the `Falco.Viewer` role. Keep **Assignment required = Yes**.
- **Falco → Sidekick uses mTLS.** Any pod in the falco namespace can obtain a
  certificate from step-ca (same CA); Sidekick's `allowedclientsans` allowlist
  enforces that only Falco's cert is accepted. Keep the list populated and never
  add pods that should not reach Sidekick to the same namespace.

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
kernel exposes CO-RE BTF, otherwise the kernel module. All three nodes —
including the control-plane `-pve` node — run the modern eBPF probe.

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

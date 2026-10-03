# falco

Envoy Gateway routing for the Falco runtime-security stack.

Falco watches syscalls on every node and raises an event when something matches a
rule — a shell opened inside a container, a write under `/etc`, a process reading
`/etc/shadow`, an unexpected outbound connection. Falcosidekick fans those events
out, and the Falcosidekick UI is the console you actually look at.

## What lives where

This chart now contains:
- **HTTPRoutes** for the UI (Envoy Gateway routing)
- **UI Deployment and Redis StatefulSet** (TLS-enabled, auto-cert, hot-reload certs)
- **NetworkPolicies** for ingress control
- **UI configuration** (ConfigMap with OIDC + ingestion settings, TLS settings)
- **BackendTLSPolicy** for Envoy → UI TLS validation

Falco and Falcosidekick come from the upstream `falcosecurity/falco` chart (our forked
Sidekick image). We manage the UI and Redis here because the upstream chart offers
no TLS support (hard-coded HTTP probes, plaintext redis-cli ping, no hot reload).

| Piece | Chart | Values |
| --- | --- | --- |
| Falco + Sidekick | `falcosecurity/falco` | `falco__falco.yaml` |
| HTTPRoutes, UI Deployment, Redis StatefulSet, NetworkPolicies, BackendTLSPolicy | this chart | `falco__falco-gw.yaml` |

`values.example.yaml` shows the upstream release's values with placeholders.

## Installation

First install, or migrating from upstream embedded UI/Redis:

```sh
# Define paths once at the top
CHARTS=~/Projects/git-repos/kscsc-helm-charts
V=$CHARTS/config/values
CONFIG=$CHARTS/config

helm repo add falcosecurity https://falcosecurity.github.io/charts --force-update
helm repo update falcosecurity

# 0. Create the namespace with autocert label (enables mTLS cert injection).
#    autocert must be running with restrictCertificatesToNamespace: true.
kubectl apply -f "$CHARTS/config/manifests/falco-namespace.yaml"

# 1. Upgrade autocert to ensure it is running with the latest config.
#    Then restart the controller so new pods get injected correctly.
helm upgrade --install autocert smallstep/autocert -n autocert --create-namespace \
  -f "$V/autocert__autocert.yaml"
kubectl -n autocert rollout restart deploy/autocert

# 2. (Optional) Back up Redis if you are migrating from the upstream UI/Redis.
#    PVC and data survive the helm upgrade.
#    kubectl -n falco exec falco-falcosidekick-ui-redis-0 -- redis-cli BGSAVE
#    sleep 5
#    kubectl -n falco cp falco-falcosidekick-ui-redis-0:/data/dump.rdb ~/falco-redis-dump-$(date +%Y%m%d).rdb

# 3. Remove the old UI and Redis from the upstream Falco release.
#    The PVC survives (it came from a volumeClaimTemplate; Helm does not delete it).
helm upgrade --install falco falcosecurity/falco -n falco \
  -f "$V/falco__falco.yaml"

# 4. Wait for the old Redis pod to be deleted. It is StatefulSet pod 0.
#    Two Redis on one RWO PVC directory will corrupt the data.
kubectl -n falco wait --for=delete pod/falco-falcosidekick-ui-redis-0 --timeout=120s

# 5. Now install the new falco-gw release with the UI and Redis. 
#    It will mount the same PVC and keep the event history.
helm upgrade --install falco-gw "$CHARTS/falco" -n falco \
  -f "$V/falco__falco-gw.yaml"
```

Then browse to <https://falco.kscsc.local>.

**Why this order:**
- The namespace label must exist **before** any pod (for autocert injection).
- **autocert must be upgraded and restarted first** — new pods created after that
  get mutated with cert volumes; existing pods are unaffected.
- **Remove the old upstream UI/Redis before creating the new ones** — the
  `redis.existingClaim` value in `falco-gw` points to the old PVC name. A local-path
  PVC is RWO (ReadWriteOnce), so only one pod can mount it at a time. If two Redis
  servers run against the same PVC directory at once, the data will be corrupted.
  The old StatefulSet pod must be fully gone before the new one mounts it.
- Waiting for pod deletion ensures clean data handoff.


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

1. **Falco → Sidekick mTLS** via step-ca autocert
2. **Secrets and authentication** for browsers, ingestion, and Redis
3. **NetworkPolicies** restricting which pods can talk to which services

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
Sidekick's `tlsserver` deploys as mTLS server with **hot reload**: it checks cert
file contents (not mtimes) once every 30 seconds (fixed) and reloads on change,
logging reloads and errors separately.

Sidekick's `allowedclientsans` list restricts client certificates by their SubjectAlternativeName (or Subject.CommonName): only Falco's cert is accepted. The client identity is proved by:
- the KSCSC root CA (Sidekick verifies the signature),
- autocert's `restrictCertificatesToNamespace: true` (only pods in the `falco` namespace can request `falco.*.svc.cluster.local` names),
- the `allowedclientsans` allowlist (Falco's SAN name).

**Pods in the `falco` namespace are explicitly trusted.** Do not run untrusted workloads there. The Sidekick image must be the forked version with hot reload and SAN verification; an older image ignores `TLSSERVER_ALLOWEDCLIENTSANS` and would serve an expired cert after 24h.

Probes use the plain-HTTP port `http-notls: 2810` (path `/ping` with no auth),
while the secure port `:2801` stays for Falco only.

### Secrets and authentication

- **Browsers**: a public OIDC client with PKCE against Entra ID, gated by user
  assignment and the `Falco.Viewer` app role.
- **Sidekick → UI ingestion**: a projected, short-lived ServiceAccount token (bearer auth)
  plus mTLS with Sidekick's step-ca cert.
- **UI → Redis**: mTLS, both sides using step-ca certs from autocert.
- **Redis authentication**: no password; access control via NetworkPolicy (UI pods only)
  plus TLS client-certificate verification on the server side.

The UI's configuration lives in the ConfigMap `falco-ui-config`, rendered by this chart
from the `uiAuth:` values block (OIDC settings, ingest settings) plus new TLS settings
(cert/key files, allowed mTLS SANs for ingestion, Redis connection TLS). It contains
no secret material. `tenantId` and `clientId` are identifiers, not credentials; the
real ones are in the private config repo.

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

### Redis (TLS with least-privilege default user and restart-based cert reload)

Redis (`redis-stack:7.2.0-v11`, includes RediSearch + ReJSON) runs on TLS port 6379
with client-cert verification (`tls-auth-clients yes`). It has **no password**; the
only authentication is certificate verification by SAN. Its access control is:
- TLS client certificate matching the expected SAN (`falco-ui.falco.svc.cluster.local`)
- NetworkPolicy (port 6379 from UI pods only)
- ACL-enforced least-privilege: the `default` user is restricted to only the commands
  the UI actually needs (`FT.CREATE`, `FT.INFO`, `FT.ADD`, `FT.SEARCH`, `FT.AGGREGATE`,
  `EXPIRE`, `SETEX`, `GET`, `GETDEL`, `SET`, `DEL`, `PING`), blocking dangerous
  operations like `CONFIG SET`, `MODULE LOAD`, `EVAL`, `FLUSHALL`, `REPLICAOF`, etc.

Redis 7.2 cannot map client certificates to ACL users (that feature exists in Valkey
7+), so every mTLS client is the `default` user. The ACL still blocks most dangerous
commands and provides defense in depth. A liveness probe detects certificate renewals
(24h lifetime, rotated continuously) by comparing SHA256(site.crt + site.key) against
a hash written at startup. When the hash differs, the probe fails, triggering a pod
restart that picks up the new cert. This happens about once a day for 30 seconds while
the pod restarts; the data persists via RDB save on SIGTERM.

Enable the policies (`networkPolicy.enabled: true`); without them, any pod can hit
Redis and wipe the 7-day event history.

### TLS Architecture

Every hop is authenticated:

| Hop | Protocol | Cert Issuer | Client Cert | Server Verifies |
| --- | --- | --- | --- | --- |
| Falco → Sidekick `:2801` | mTLS | step-ca autocert | `falco.falco.svc.cluster.local` | Client SAN vs allowedclientsans |
| Sidekick → UI (mTLS ingestion) | mTLS | step-ca autocert | `falco-falcosidekick.falco.svc.cluster.local` | Client SAN via mTLS middleware |
| Sidekick → UI (bearer token output) | HTTPS (TLS only) | step-ca autocert | — | Certificate + ServiceAccount token validation |
| Envoy → UI | mTLS (BackendTLSPolicy) | step-ca autocert | none (one-way TLS) | Server hostname `falco-ui.falco.svc.cluster.local` |
| UI → Redis | mTLS | step-ca autocert | `falco-ui.falco.svc.cluster.local` | Server checks client SAN |

All certs have 24-hour lifetime and are rotated continuously by step-ca. Falco, Sidekick, UI,
and Redis all carry `autocert.step.sm/name: <dns-name>` annotations so that autocert injects
an init container (fetch initial cert) and a renewer sidecar (hot-reload on change).
The UI runs a cert-reloader sidecar that checks cert freshness every 30 seconds.
Redis detects cert renewal via liveness probe and restarts to load the new cert.

- **Probes**: Falco and Sidekick use a plain-HTTP probe port (notlsport). The UI
  probes `/api/v1/healthz` over HTTPS. Redis uses a TLS exec probe via `redis-cli --tls`.
- **Hostname verification**: Each service verifies the peer's hostname (SAN or CN) to ensure
  it is talking to the right pod (not a different pod in the cluster with a different cert).
- **NetworkPolicies** restrict the network paths, but TLS provides cryptographic proof of identity.

### Residual risks

- **NetworkPolicies must be enforced.** If they are off or not enforced (CNI without
  policy support, a mistaken selector), any pod in the cluster can reach Redis and wipe
  the event store, or reach the UI and ingest false events. Verify enforcement after
  every CNI change: `kubectl -n falco get pods` → all Ready, events still flowing.
- **Redis default user is shared by all mTLS clients.** Redis 7.2 cannot map client
  certificates to ACL users, so every mTLS client is the `default` user. The ACL
  restricts dangerous commands (CONFIG SET, MODULE LOAD, EVAL, FLUSHALL, etc.) so the
  default user cannot disable itself. The NetworkPolicy `falco-ui-redis: 6379 from
  falco-ui pods only` + TLS client-cert verification on the server side ensure only
  the UI reaches Redis. Future work: Valkey 7+ supports certificate→user mapping;
  switching there would enable per-client identity in Redis.
- **Pod identity spoofing via shared CA.** All pods in the `falco` namespace obtain
  certs from the same KSCSC step-ca with `restrictCertificatesToNamespace: true`. Any
  pod in the namespace can request a `*.falco.svc.cluster.local` name and get a valid cert.
  Sidekick's `TLSSERVER_ALLOWEDCLIENTSANS` allowlist and the UI's mTLS ingestion middleware
  validate the peer's identity cryptographically. Do not run untrusted workloads in the
  `falco` namespace.
- The public client (Entra ID) has no secret to leak, but also nothing that stops someone
  from starting a login flow; protection depends entirely on Entra assignment and the
  `Falco.Viewer` role. Keep **Assignment required = Yes**.
- **Autocert webhook has `failurePolicy: Ignore`.** If the autocert mutating webhook is
  down when a pod is created, the pod gets no certs. Sidekick then crash-loops visibly,
  but Falco starts and silently fails to send events (no output, no errors). After any
  node or pod churn, check that every Falco pod has an `autocert-renewer` container with
  a `Ready` status.
- **Alerts are lost during mTLS upgrades.** When the deployment adds or changes mTLS
  settings, old and new pods run simultaneously: old pods use `http://` (pre-mTLS or different
  port), new pods demand mTLS on `:2801`. Falco pods may briefly fail to connect. This is
  expected and resolves within a minute as the rolling update completes.

### NetworkPolicies

`networkPolicy.enabled: true` renders three ingress-only policies (egress stays
open: the UI needs Entra ID and the API server, Sidekick its outputs):

| Pod | Port | Allowed from |
| --- | --- | --- |
| Redis (`app.kubernetes.io/name=falco-ui-redis`) | 6379 | UI pods (`app.kubernetes.io/name=falco-ui`) only |
| UI (`app.kubernetes.io/name=falco-ui`) | 2802 | Sidekick pods and namespace `envoy-gateway-system` |
| Sidekick (`app.kubernetes.io/name=falcosidekick`, `app.kubernetes.io/component=core`) | 2801 | Falco DaemonSet pods (`app.kubernetes.io/name=falco`) only |

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

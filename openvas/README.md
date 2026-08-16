# 🛡️ OpenVAS / Greenbone Community Edition

Greenbone Community Edition (feed release **24.10**) as a single Helm release, for scanning
the `192.168.95.0/24` lab network. TLS is terminated by Envoy Gateway with a step-ca
certificate, like every other chart here.

```bash
helm upgrade --install openvas ./openvas -n openvas --create-namespace \
  -f ./config/values/openvas__openvas.yaml
```

---

## 📐 Why it is one pod

Upstream ships this as a **21-service docker-compose stack**. The services do not talk over
the network — they talk over **shared unix sockets**:

| Socket volume | Path | Shared by |
| :--- | :--- | :--- |
| `gvmd_socket` | `/run/gvmd` | gvmd ↔ gsad ↔ gvm-tools |
| `ospd_openvas_socket` | `/run/ospd` | ospd-openvas ↔ gvmd |
| `redis_socket` | `/run/redis` | redis-server ↔ ospd-openvas |
| `psql_socket` | `/var/run/postgresql` | pg-gvm ↔ gvmd ↔ migrator |

The only storage class in this cluster is `local-path`, which is **RWO and node-local**.
There is no RWX class, so a socket directory cannot be shared between pods. That forces the
entire stack into **one pod: 12 init containers + 7 long-running containers** (8 with the
admin bootstrap), pinned by `nodeSelector` to the node holding the disk.

Kubernetes runs init containers strictly in order, which reproduces the "wait for this to
finish" half of compose's `depends_on` graph for free. The other half — `service_started`
edges like gvmd→pg-gvm — is handled by the daemons themselves: `gvmd`'s start script polls
for `$PGRES_DATA/started` and retries `psql` until Postgres answers.

---

## ⚠️ Four upstream behaviours that had to be worked around

These are not preferences. Each one prevents the stack from starting under Kubernetes.

### 1. `KEEP_ALIVE` must be **absent**, not `0`

Every Greenbone init image ends with:

```sh
if [ -n "${KEEP_ALIVE}" ]; then
    sleep infinity
fi
```

`[ -n "0" ]` is **true** in POSIX sh. Setting `KEEP_ALIVE=0` — the intuitive translation of
compose's `KEEP_ALIVE: 1` — makes the container sleep forever and the pod hangs at
`Init:3/12`. The templates omit the variable entirely. Don't add it back.

### 2. nginx's HTTP port is a redirect-only listener by default

`gvm-config` renders this:

```nginx
{%- if enable_http_redirect %}
server { listen {{nginx_http_port}}; return 301 https://$host:{{nginx_https_port}}$request_uri; }
{%- endif %}
```

with `NGINX_ENABLE_HTTP_REDIRECT` defaulting to `true` and `NGINX_ENABLE_HTTP` to `false`.
Since Envoy terminates TLS and forwards plaintext, the default config answers every request
with `301 → https://openvas.kscsc.local:443`, which is Envoy again — an infinite loop. The
chart sets `NGINX_ENABLE_HTTP=true` and `NGINX_ENABLE_HTTP_REDIRECT=false`.

### 3. nginx and gsad both want port 9392

`NGINX_HTTP_PORT` defaults to `9392`, and gsad also listens on `9392`. Across two compose
containers that is fine; inside one pod it is a bind conflict. nginx is moved to **8080**.

### 4. Generated configs reference compose service names

nginx has a hardcoded `upstream gsad { server gsad:9392; }` with **no environment variable to
override it**, and `openvas.conf` points at `http://openvasd:80`. Neither name resolves in a
single pod. Rather than patching generated files, the pod declares:

```yaml
hostAliases:
  - ip: "127.0.0.1"
    hostnames: [gsad, openvasd]
```

Note this is also why `hostNetwork: true` is not offered as a toggle — `hostAliases` is
ignored on host-network pods, so that mode would need a different fix entirely.

---

## 💾 Storage

Seven PVCs, one per upstream named volume. This is deliberate.

`gvmd` mounts `scap-data`, `cert-data` and `data-objects/gvmd` at paths **nested inside** its
own `/var/lib/gvm` mount. Nesting *distinct volumes* that way is ordinary Linux behaviour and
is exactly what compose does. Collapsing them into subPaths of a **single** PVC is not — that
arrangement is mount-order dependent and is [reported to
fail](https://github.com/fpm-git/Greenbone-Community-Edition-Helm). local-path does not
enforce PVC sizes anyway, so extra claims cost nothing.

| Claim | Default | Holds |
| :--- | :--- | :--- |
| `scap-data` | 15Gi | Extracted CVE/CPE data — the largest feed |
| `psql-data` | 20Gi | Postgres: imported feeds + scan results |
| `vt-data` | 10Gi | NVT plugins |
| `gvmd-data` | 5Gi | gvmd state |
| `notus-data` | 2Gi | Notus advisories |
| `cert-data` | 2Gi | CERT-Bund + DFN-CERT |
| `data-objects` | 1Gi | Scan configs, port lists, report formats |

> **local-path cannot expand a PVC after creation.** Size these up front; growing one later
> means a new claim, an `rsync`, and a cutover.

**No `fsGroup` is set, on purpose.** local-path already creates volumes mode `0777`, and an
`fsGroup` would make `PGDATA` group-accessible — which Postgres refuses to start on.

---

## 🌐 Scanning the LAN

The pod sits on the cluster network. k3s/flannel masquerades everything leaving the pod CIDR,
so scan traffic reaches `192.168.95.0/24` SNAT'd to the node's address.

| | |
| :--- | :--- |
| ✅ Works | TCP connect, SYN/raw (`NET_RAW`), UDP, ICMP echo, all NVT checks over those |
| ❌ Doesn't | **ARP ping** — L2 frames never cross the VXLAN overlay onto the physical LAN |
| ⚠️ Untested | OOB/callback checks where the target must open a *fresh inbound* connection to the scanner; SNAT has no reverse mapping for those |

Greenbone ORs its alive tests, so a host answering ICMP *or* any TCP port is still discovered.
Only a host that blocks ICMP **and** exposes no TCP port goes missing — set that target's
**Alive Test** to *Consider Alive* in the UI.

`ospd-openvas` is the sole privileged container: `NET_ADMIN` + `NET_RAW`, with seccomp and
AppArmor unconfined, matching upstream. Note that **NetworkPolicy is not enforced in this
cluster** (flannel, no policy controller), so `templates/networkpolicy.yaml` documents intent
rather than containing anything.

---

## ⏱️ First start takes 30–60+ minutes

- ~2.7 GB of images pull first, and kubelet serialises image pulls by default
- then `gvmd` imports SCAP and CERT into Postgres before it answers on its socket

Only nginx carries a `readinessProbe`, so the pod goes `Ready` well before the UI is usable.
That is intentional: pod readiness is an AND across every probed container, so probing the
sidecars would let one unhealthy helper pull the web UI out of the Service.

```bash
kubectl -n openvas logs -f deploy/openvas-openvas -c gvmd
kubectl -n openvas logs deploy/openvas-openvas -c bootstrap-admin
```

---

## 🔑 Admin account

`gvmd` ships with no accounts. The `bootstrap-admin` container waits for gvmd's socket, then
creates the user idempotently from a Secret. It is guarded so a failure can never crashloop
the pod. Set `adminUser.forcePassword=true` to reset the password on every restart.

With `adminUser.enabled=false`, do it by hand once gvmd is up:

```bash
kubectl -n openvas exec -it deploy/openvas-openvas -c gvmd -- \
  gvmd --create-user=admin --password='<choose-one>'
```

---

## 🔐 SSO — what is and isn't possible

**Greenbone cannot do SSO.** GVM authenticates against local accounts, **LDAP** or **RADIUS**
only — there is no OIDC or SAML support in any edition, and `gsad` has no trusted-header or
reverse-proxy authentication mode. Someone [tried exactly this with Google
IAP](https://gist.github.com/moxli/02397491b90fee26edd8f5036948ea2a) and still landed on the
GSA login screen after authenticating.

So there is no way to hand an Entra ID identity through to a GSA session. What you *can* do:

### Gate the route with Entra ID (`sso.enabled=true`)

`templates/securitypolicy.yaml` attaches an Envoy Gateway `SecurityPolicy` to the HTTPRoute.
Unauthenticated users never reach GSA at all; authenticated ones then log in to GSA normally.
That is **defence in depth, effectively a second factor — not single sign-on.** For a UI that
holds your whole network's vulnerability inventory, it's still worth having.

Prerequisites:

1. An Entra ID app registration with redirect URI `https://openvas.kscsc.local/oauth2/callback`
2. The client secret in this namespace:
   ```bash
   kubectl -n openvas create secret generic openvas-oidc \
     --from-literal=client-secret='<secret from Entra>'
   ```
3. `envoy-oidc-hmac` in `envoy-gateway-system` — already present in this cluster

Then set `sso.enabled=true` and `sso.clientID` in the private values file.

> ⚠️ Caveat worth testing: GSA is a React SPA that calls `/gmp` over XHR. When the OIDC
> session expires, Envoy answers those XHR calls with a 302 to Entra, which the SPA cannot
> follow — the UI may fail oddly rather than cleanly re-prompting. `SecurityPolicy` has a
> `denyRedirect` field to return an error instead of redirecting; wire it up if this bites.

### True single-credential login: LDAP

`gvmd` supports LDAP, configurable in the GSA UI under *Administration → LDAP*. Note that
**users must still be created in GSA first** — LDAP only validates the password, it does not
provision accounts. Entra ID does not speak plain LDAP without Entra Domain Services, so this
route needs a real directory (an AD lab, or Domain Services).

---

## 🔄 Keeping feeds current

The feed-data images are tagged `latest` and rebuilt continuously by Greenbone, and
`image.pullPolicy` is `Always`. Restarting the deployment re-pulls them and re-runs the init
containers:

```bash
kubectl -n openvas rollout restart deploy/openvas-openvas
```

Bump `feedRelease` in step with upstream's `compose.yaml` when Greenbone moves past 24.10.

# myfinance Helm Chart

Deploys [MyFinance](https://github.com/swiru95/MyFinance) — a self-hosted budget and
portfolio tracker — as a Next.js frontend and a FastAPI backend behind the cluster's
Envoy Gateway.

This chart lives in the infrastructure repository. The application source stays in the
`MyFinance` repository; the two images are built from it and pushed to GHCR.

## Architecture

```
                                   ┌──────────────────────────────────────────────┐
                                   │              k3s cluster                     │
  Browser                          │              namespace: myfinance            │
  https://myfinance.kscsc.local    │                                              │
        │                          │   ┌──────────────────────────────────────┐   │
        │                          │   │  Deployment: frontend                │   │
        ▼                  path /  │   │  Next.js 14 standalone :3000         │   │
  ┌───────────────┐───────────────►│   └──────────────────────────────────────┘   │
  │ Envoy Gateway │                │                                              │
  │ 192.168.95.51 │   path /api    │   ┌──────────────────────────────────────┐   │
  │  :80 → :443   │───────────────►│   │  Deployment: backend  (Recreate)     │   │
  └───────┬───────┘                │   │  FastAPI / uvicorn :8000             │   │
          │                        │   │  /api/health  ◄── probes             │   │
     envoy-gateway-tls             │   └──────────────┬───────────────────────┘   │
     (step-ca via cert-manager)    │                  │ SQLite                    │
     SAN: myfinance.kscsc.local    │                  ▼                           │
                                   │   ┌──────────────────────────────────────┐   │
                                   │   │  PVC: myfinance-myfinance-data (2Gi) │   │
                                   │   │  /app/data/myfinance.db              │   │
                                   │   └──────────────────────────────────────┘   │
                                   └──────────────────────────────────────────────┘
                                                      │ egress (unrestricted)
                                                      ▼
                                   open.er-api.com · gold-api.com · CoinGecko
```

One hostname, split on path at the gateway: `/api/*` reaches FastAPI, everything else
reaches Next.js. The browser therefore stays on a single origin and never sees CORS.

**The Next.js `/api` proxy is deliberately not used here.** `next.config.js` does define a
rewrite to `$BACKEND_ORIGIN`, but `next build` resolves it into
`.next/routes-manifest.json`, so the standalone server ignores the environment variable at
runtime and keeps dialling the docker-compose host `backend`. Setting `BACKEND_ORIGIN` on
the frontend Deployment would look like it worked and quietly do nothing — so the chart
does not set it, and the gateway does the routing instead. That also keeps the image free
of any Service-name coupling.

## Prerequisites

- Both images in GHCR (built by CI, see below) and, unless the packages are public, a
  `ghcr-pull-secret` in the namespace.
- `myfinance.kscsc.local` in the `envoy-gateway-tls` Certificate's `dnsNames`
  (`envoy/values.yaml`) — otherwise the gateway serves a cert that does not match.
- `myfinance.kscsc.local` in `coreDNS/values.yaml` under `hosts.envoy`, and in
  `/etc/hosts` on any client outside the cluster, pointing at `192.168.95.51`.

## Images

Both images are built by GitHub Actions in
[swiru95/MyFinance](https://github.com/swiru95/MyFinance) on every push to `main`
(`.github/workflows/build-images.yml`) and published to GHCR tagged with the commit SHA.
The workflow authenticates with the built-in `GITHUB_TOKEN`, so no personal access token
is involved.

Deploying a new build is therefore a values change, not a rebuild:

```bash
helm upgrade --install myfinance ./myfinance -n myfinance \
  -f ./config/values/myfinance__myfinance.yaml \
  --set backend.image.tag=<sha> --set frontend.image.tag=<sha>
```

Rolling back is the same command with the previous SHA.

**GHCR packages start out private even when the source repository is public.** Either
make both `myfinance-backend` and `myfinance-frontend` public under the repository's
Packages settings and set `imagePullSecrets: []`, or keep the secret in the namespace:

```bash
kubectl create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username=swiru95 \
  --docker-password=<GHCR_PAT_with_read:packages> \
  -n myfinance
```

To build by hand instead (matching what CI does):

```bash
TAG=$(git rev-parse HEAD)
docker build -t ghcr.io/swiru95/myfinance-backend:$TAG  ./backend
docker build -t ghcr.io/swiru95/myfinance-frontend:$TAG ./frontend
docker push ghcr.io/swiru95/myfinance-backend:$TAG
docker push ghcr.io/swiru95/myfinance-frontend:$TAG
```

## Installing

```bash
helm upgrade --install myfinance ./myfinance -n myfinance --create-namespace \
  -f ./config/values/myfinance__myfinance.yaml
```

Then add the hostname to the gateway certificate and cluster DNS:

```bash
helm upgrade --install envoy-resources ./envoy -n envoy-gateway-system \
  -f ./config/values/envoy-gateway-system__envoy-resources.yaml
helm upgrade --install coredns-custom ./coreDNS -n kube-system
```

> Do not pass `--wait` to the envoy-resources upgrade. cert-manager reissues the
> Certificate when `dnsNames` changes, and the Secret is briefly absent while it does —
> `--wait` reads that as a failure and marks the release failed even though it converges
> a few seconds later.

## Values

| Key | Default | Description |
| :--- | :--- | :--- |
| `backend.image.repository` / `.tag` | `ghcr.io/swiru95/myfinance-backend` / `0.1.0` | Backend image |
| `frontend.image.repository` / `.tag` | `ghcr.io/swiru95/myfinance-frontend` / `0.1.0` | Frontend image |
| `imagePullSecrets` | `[{name: ghcr-pull-secret}]` | Pull secret for the private GHCR packages |
| `cors.origins` | `[https://myfinance.kscsc.local]` | `MYFINANCE_CORS_ORIGINS` on the backend |
| `auth.enabled` | `true` | Entra ID SSO. `false` leaves every API endpoint open |
| `auth.tenantId` / `.clientId` | *(empty)* | Public client identifiers. Required when `auth.enabled`; the chart refuses to render without them |
| `auth.apiScope` | `access_as_user` | Scope exposed on `api://<clientId>` and requested by the SPA |
| `auth.requiredRole` | `MyFinance.User` | App role the caller must hold. Empty admits anyone in the tenant |
| `gateway.hostname` | `myfinance.kscsc.local` | HTTPRoute hostname |
| `gateway.apiPathPrefix` | `/api` | Prefix routed to the backend; must match `BASE` in `frontend/src/lib/api.ts` |
| `gateway.httpDirect` | `false` | `false` redirects :80 → :443; `true` serves plaintext |
| `gateway.timeout` | `60s` | Request and backend-request timeout |
| `pvc.enabled` / `.size` | `true` / `2Gi` | SQLite volume at `/app/data` |
| `networkPolicy.enabled` | `true` | Gateway → frontend and gateway → backend; nothing else |
| `tolerations` | `nvidia.com/gpu` | Every node in this cluster carries the GPU taint |

## Operational notes

- **One backend replica, `Recreate` strategy.** The database is a single SQLite file on a
  ReadWriteOnce volume; a rolling upgrade would briefly have two uvicorn processes
  holding it open. Do not raise `replicas`.
- **Back up before upgrading the backend image**, since the schema is created by
  `Base.metadata.create_all` on startup:
  ```bash
  kubectl exec -n myfinance deploy/myfinance-myfinance-backend -- \
    cat /app/data/myfinance.db > myfinance.db.bak-$(date +%Y%m%d-%H%M%S)
  ```
- **Egress is deliberately unrestricted.** The price service calls out to
  `open.er-api.com`, `gold-api.com` and CoinGecko, and falls back to static rates when
  they are unreachable — so the app still starts on a cluster with no internet, showing
  stale prices.
- **If `BASE` in `frontend/src/lib/api.ts` ever changes**, change `gateway.apiPathPrefix`
  with it. They are the same contract expressed in two repositories, and nothing fails
  loudly if they drift — the browser just gets the Next.js 404 page for API calls.

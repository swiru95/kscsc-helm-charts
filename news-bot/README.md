# news-bot Helm Chart

Deploys news-bot (cybersecurity news pipeline) and linkedin-feeder (auto-posting) on Kubernetes as two CronJobs sharing a PVC.

This chart lives in the infrastructure repository. The application image and source code stay in the `news-bot` repository.

## Architecture

```
                         ┌─────────────────────────────────────────────────────────┐
                         │                    k3s cluster                          │
                         │                    namespace: news-bot                  │
                         │                                                         │
┌─────────────────────────┐  ┌──────────────────┐       ┌────────────────────────┐ │
│  llama-server (llama.   │  │  CronJob         │       │  CronJob               │ │
│  cpp)                   │  │  news-bot        │       │  linkedin-feeder       │ │
│  llama.kscsc.local:8443 │  │  14:00 M-F       │       │  16:00 M-F             │ │
└────────┬────────────────┘  │                  │       │                        │ │
         │                   │  1. Fetch RSS    │       │  1. Read NEWS.md       │ │
         │                   │  2. Dedup+Embed  │       │  2. Summarize (LLM)    │ │
         ├──────────────────►│  3. Cluster (LLM)│       │  3. Post to LinkedIn   │ │
         │                   │  4. Rank+Source  │       │  4. Reshare personal   │ │
         │                   │  5. Summarize    │       │                        │ │
         └──────────────────►│  6. Write output │       │  Auto-refreshes tokens │ │
                             └───────┬──────────┘       └───────┬──────┬─────────┘ │
                         │           │                          │      │           │
                         │           │ write                read│      │write      │
                         │           ▼                          │      │           │
                         │  ┌────────────────────────────────┐  │      │           │
                         │  │  PVC: news-bot-data (1 Gi)     │◄-┘      │           │
                         │  │  /data/output/                 │         │           │
                         │  │  ├── news.json                 │         │           │
                         │  │  ├── NEWS.md ──────────────────┼─────────┘           │
                         │  │  ├── .news_bot_state.json      │                     │
                         │  │  └── .linkedin_tokens.json ◄───┼─── token cache      │
                         │  └────────────────────────────────┘     (auto-refresh)  │
                         │                                                         │
                         │  ┌────────────────────┐  ┌─────────────────────────┐    │
                         │  │  ConfigMap         │  │  Secret                 │    │
                         │  │  news-bot-config   │  │  news-bot-secrets       │    │
                         │  │  ┌────────────────┐│  │  ┌───────────────────┐  │    │
                         │  │  │ config.yaml    ││  │  │ CLIENT_ID         │  │    │
                         │  │  │ LLM_API_URL    ││  │  │ CLIENT_SECRET     │  │    │
                         │  │  │ LLM_MODEL      ││  │  │ ORG_URN           │  │    │
                         │  │  │ ORG_NAME       ││  │  │ ORG_TOKEN         │  │    │
                         │  │  │ ORG_URL        ││  │  │ ORG_REFRESH_TOKEN │  │    │
                         │  │  └────────────────┘│  │  │ PERSONAL_TOKEN    │  │    │
                         │  │                    │  │  │ PERSONAL_REFRESH  │  │    │
                         │  │  ConfigMap         │  │  └───────────────────┘  │    │
                         │  │  news-bot-feeds    │  └─────────────────────────┘    │
                         │  │  ┌────────────────┐│                                 │
                         │  │  │ Feeds.xml      ││           ┌──────────────┐      │
                         │  │  │ (RSS feeds)    ││           │  LinkedIn    │      │
                         │  │  └────────────────┘│           │  REST API    │      │
                         │  └────────────────────┘           └──────────────┘      │
                         │                                                         │
                         └─────────────────────────────────────────────────────────┘
```

## Prerequisites

- Kubernetes 1.27+
- Helm 3.x
- Built and published or imported `news-bot` image
- OpenAI-compatible LLM endpoint reachable from the cluster (currently llama-server at `llama.kscsc.local:8443`, HTTPS)
- LinkedIn Developer App with OAuth 2.0 credentials

## Build the application image

Build the container from the application repository before installing or upgrading this chart:

```bash
cd ../news-bot
docker build -t ghcr.io/swiru95/news-bot:latest .
```

If your cluster does not pull from GHCR directly, tag and publish or import the image using your existing cluster workflow.

The current chart defaults use a pinned GHCR image and the llama-server (llama.cpp)
endpoint at `https://llama.kscsc.local:8443/v1/chat/completions`. That endpoint
requires an API key, needed by both the main news-bot pipeline and the linkedin-feeder.

The API key can be supplied in two ways:

**Chart-managed Secret** (`secrets.create=true`):
```bash
helm install news-bot ./news-bot \
  --set secrets.create=true \
  --set ollama.authHeader="Bearer <key>"
```

**Pre-existing Secret** (the default, `secrets.existingSecret: news-bot-secrets`):
Add the key directly to the secret:
```bash
kubectl create secret generic news-bot-secrets -n news-bot \
  --from-literal=llm-auth-header="Bearer <key>" \
  --from-literal=linkedin-client-id=<...> \
  --dry-run=client -o yaml | kubectl apply -f -
```

**Warning:** this form of `kubectl apply` replaces the Secret's contents, so you must
include the existing LinkedIn keys in the same command. A safer alternative:
```bash
kubectl patch secret news-bot-secrets -n news-bot \
  -p '{"stringData":{"llm-auth-header":"Bearer <key>"}}'
```

In either case, the key is deliberately empty in `values.yaml` so it is never committed.

### Migrating the API key out of the ConfigMap

During the transition, `--set ollama.authHeader=...` renders the key into BOTH the Secret and
the ConfigMap as `auth_header` (for backward compatibility with the main pipeline's config.yaml).
Once the Secret key is provisioned in the cluster, upgrade without `--set ollama.authHeader`:

```bash
helm upgrade news-bot ./news-bot --reuse-values
```

The ConfigMap's `auth_header` line then disappears while the environment variables keep both jobs
working off the Secret.

## Install the chart

```bash
helm install news-bot ./news-bot \
  --namespace news-bot --create-namespace \
  --set-file feeds.inline=../news-bot/Feeds.xml \
  --set secrets.linkedin.clientId=YOUR_CLIENT_ID \
  --set secrets.linkedin.clientSecret=YOUR_CLIENT_SECRET \
  --set secrets.linkedin.orgUrn=urn:li:organization:YOUR_ORG_ID \
  --set secrets.linkedin.orgToken=YOUR_ACCESS_TOKEN \
  --set secrets.linkedin.orgRefreshToken=YOUR_REFRESH_TOKEN
```

## Verify the deployment

```bash
kubectl get cronjobs -n news-bot

kubectl create job news-bot-test --from=cronjob/news-bot -n news-bot
kubectl logs -f job/news-bot-test -n news-bot

kubectl create job linkedin-test --from=cronjob/news-bot-linkedin -n news-bot
kubectl logs -f job/linkedin-test -n news-bot
```

## Updating

```bash
helm upgrade news-bot ./news-bot --reuse-values
```

Default schedules in this chart:

- `news-bot`: `0 14 * * 1-5`
- `news-bot-linkedin`: `0 16 * * 1-5`

## Manual pipeline check

To verify that fresh news are generated, create a one-off job from the main CronJob and stream its logs:

```bash
kubectl create job news-bot-manual --from=cronjob/news-bot -n news-bot
kubectl logs -f job/news-bot-manual -n news-bot
```

The expected outputs are written into the shared PVC at `/data/output/NEWS.md`, `/data/output/news.json`, and `/data/output/.news_bot_state.json`.

## Config mapping

The chart renders the application `config.yaml` into a ConfigMap. The main values map directly to the current app schema:

- `config.embeddingModel` -> `settings.embedding_model`
- `config.dropNonEnglish` -> `settings.drop_non_english`
- `config.stateRetentionDays` -> `settings.state_retention_days`
- `ollama.provider` -> `settings.llm.provider`
- `ollama.authSource` -> `settings.llm.auth_source`
- `ollama.webSearch` -> `settings.llm.web_search`
- `ollama.ollamaBaseUrl` -> `settings.llm.ollama_base_url`

Environment variables passed to the linkedin-feeder CronJob:

- `ollama.apiUrl` -> `LLM_API_URL`
- `ollama.model` -> `LLM_MODEL`
- `ollama.timeout` -> `LLM_TIMEOUT`
- `ollama.tlsVerify` -> `LLM_TLS_VERIFY`
- `ollama.authSecretKey` -> Secret key mounted as `LLM_AUTH_HEADER`

Current defaults match the tuned live deployment profile: 24h article window, `topN: 5`, non-English filtering enabled, web research disabled, source validation disabled, and the llama-server endpoint.

To roll out a new image:

```bash
helm upgrade news-bot ./news-bot \
  --reuse-values \
  --set image.tag=v2
```

## Uninstall

```bash
helm uninstall news-bot -n news-bot
kubectl delete pvc news-bot-data -n news-bot
```

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
                         │  │  │ OLLAMA_HOST    ││  │  │ CLIENT_SECRET     │  │    │
                         │  │  │ OLLAMA_MODEL   ││  │  │ ORG_URN           │  │    │
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

The API key can be supplied in two ways. Both entry points read the **raw** key (no
`Bearer ` prefix) from `OLLAMA_API_KEY` and add the scheme themselves.

**Chart-managed Secret** (`secrets.create=true`):
```bash
helm install news-bot ./news-bot \
  --set secrets.create=true \
  --set ollama.apiKey="<key>"
```

**Pre-existing Secret** (the default, `secrets.existingSecret: news-bot-secrets`):
add the key directly to the Secret — `ollama.apiKey` is ignored when the chart does
not own the Secret.
```bash
kubectl patch secret news-bot-secrets -n news-bot \
  -p '{"stringData":{"llm-api-key":"<key>"}}'
```

Avoid the `kubectl create secret ... --dry-run=client -o yaml | kubectl apply -f -`
form unless you list every existing key in the same command: it replaces the
Secret's contents rather than merging.

In either case the key is deliberately empty in `values.yaml` so it is never committed.

`ollama.authHeader` is the legacy escape hatch for a non-Bearer scheme. It is rendered
into the ConfigMap's `config.yaml` in clear text and is honoured only by the pipeline —
the linkedin-feeder ignores it. Leave it empty and use `ollama.apiKey`.

### Model selection

`ollama.model` is a **preset name** served by the llama-server router
(`/etc/llama-server/models.ini` on `llama.kscsc.local`), not a HuggingFace repo — the
router resolves the preset to its `hf-repo` itself. Current presets:

| Preset | Model | ctx |
|---|---|---|
| `Coder` | Qwen3.6-35B-A3B | 262144 (2 slots) |
| `Thinker` | Qwen3.5-122B-A10B | 65536 |
| `Bielik` | Bielik-11B-v3.0-Instruct | 32768 |

The pipeline can use two at once: `ollama.model` for the judgment stages and
`ollama.fastModel` for the mechanical big-batch ones. Confirm what the server
actually serves before switching:

```bash
curl -sk -H "Authorization: Bearer <key>" https://llama.kscsc.local:8443/v1/models
```

## Post illustration (Google AI)

The linkedin-feeder can attach a generated illustration to the daily post. The image
*subject* is written by the pipeline into `news.json` (`linkedin_post.image_prompt`);
the feeder wraps it in a fixed style/safety contract and renders it through Google's
hosted image API. The feature is cosmetic by design — no key, a quota error or an
unusable response all publish the post as text.

It needs the key in the same Secret:

```bash
kubectl patch secret news-bot-secrets -n news-bot \
  -p '{"stringData":{"google-ai-api-key":"<google-ai-studio-key>"}}'
```

Turn it off with `googleAI.enabled=false` (drops the env var and sets
`LINKEDIN_POST_IMAGE=false`). The cluster must be able to reach
`generativelanguage.googleapis.com`.

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
- `ollama.model` -> `settings.llm.model` (judgment stages: sources, verify,
  summarize, LinkedIn post)
- `ollama.fastModel` -> `settings.llm.fast_model` (mechanical stages: refine,
  filter, categorize; omitted from `config.yaml` when empty)
- `ollama.authSource` -> `settings.llm.auth_source`
- `ollama.webSearch` -> `settings.llm.web_search`
- `ollama.ollamaBaseUrl` -> `settings.llm.ollama_base_url`

Environment variables passed to the linkedin-feeder CronJob:

- `ollama.apiUrl` -> `OLLAMA_HOST` (the `/v1/chat/completions` suffix is trimmed — the
  feeder appends its own paths)
- `ollama.model` -> `OLLAMA_MODEL`
- `ollama.tlsVerify` -> `OLLAMA_TLS_VERIFY`
- `googleAI.enabled` -> `LINKEDIN_POST_IMAGE`
- `googleAI.imageModel` -> `GOOGLE_IMAGE_MODEL`
- `googleAI.aspectRatio` -> `IMAGE_ASPECT_RATIO`
- `googleAI.imageSize` -> `IMAGE_SIZE`

Secret keys mounted into both CronJobs:

- `ollama.apiKeySecretKey` -> `OLLAMA_API_KEY` (both jobs)
- `googleAI.apiKeySecretKey` -> `GOOGLE_AI_API_KEY` (linkedin-feeder only)

Note that `ollama.timeout` reaches the pipeline through `config.yaml` only; the feeder
uses its own fixed request timeout.

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

# news-bot Helm Chart

Deploys news-bot (cybersecurity news pipeline) and linkedin-feeder (auto-posting) on Kubernetes as two CronJobs sharing a PVC.

This chart lives in the infrastructure repository. The application image and source code stay in the `news-bot` repository.

## Architecture

```
                         ┌─────────────────────────────────────────────────────────┐
                         │                    k3s cluster                          │
                         │                    namespace: news-bot                  │
                         │                                                         │
┌──────────────┐         │  ┌──────────────────┐       ┌────────────────────────┐  │
│   Ollama     │◄────────┼──┤  CronJob         │       │  CronJob               │  │
│   Server     │         │  │  news-bot        │       │  linkedin-feeder       │  │
│ (external)   │◄────────┼──┤  07:00 M-F       │       │  07:30 M-F             │  │
└──────────────┘         │  │                  │       │                        │  │
                         │  │  1. Fetch RSS    │       │  1. Read NEWS.md       │  │
                         │  │  2. Dedup+Embed  │       │  2. Summarize (Ollama) │  │
                         │  │  3. Cluster (LLM)│       │  3. Post to LinkedIn   │  │
                         │  │  4. Rank+Source  │       │  4. Reshare personal   │  │
                         │  │  5. Summarize    │       │                        │  │
                         │  │  6. Write output │       │  Auto-refreshes tokens │  │
                         │  └────────┬─────────┘       └───────┬──────┬─────────┘  │
                         │           │                         │      │            │
                         │           │ write               read│      │write       │
                         │           ▼                         │      │            │
                         │  ┌────────────────────────────────┐ │      │            │
                         │  │  PVC: news-bot-data (1 Gi)     │◄┘      │            │
                         │  │  /data/output/                 │        │            │
                         │  │  ├── news.json                 │        │            │
                         │  │  ├── NEWS.md ──────────────────┼────────┘            │
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
- Ollama endpoint reachable from the cluster
- LinkedIn Developer App with OAuth 2.0 credentials

## Build the application image

Build the container from the application repository before installing or upgrading this chart:

```bash
cd ../news-bot
docker build -t ghcr.io/swiru95/news-bot:latest .
```

If your cluster does not pull from GHCR directly, tag and publish or import the image using your existing cluster workflow.

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

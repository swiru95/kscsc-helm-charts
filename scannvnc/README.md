# scannvnc

Read-only **exposure monitor** for VNC / RDP / SSH / Telnet. A Flask dashboard
renders a SQLite tracking store; a CronJob queries the search engines
(Shodan / Censys / ZoomEye — metadata only, **no host is ever contacted**) and
upserts results into that store, so exposed endpoints are tracked over time with
first-seen / last-seen and read-only weak-posture flags.

Source: https://github.com/swiru95/ScannVNC (package `scannvnc`).

## Image

Built locally and imported into each node's containerd, matching the `-local`
tag convention used by `myfinance` (there is no in-cluster registry):

```bash
cd ~/Projects/ScannVNC
docker build -t ghcr.io/swiru95/scannvnc:0.1.1-local .
docker save ghcr.io/swiru95/scannvnc:0.1.1-local -o /tmp/scannvnc.tar
for ip in 192.168.95.10 192.168.95.11 192.168.95.12; do
  scp -i ~/.ssh/claude_id_rsa -o IdentitiesOnly=yes /tmp/scannvnc.tar swiru@$ip:/tmp/
  ssh -i ~/.ssh/claude_id_rsa -o IdentitiesOnly=yes swiru@$ip \
    'sudo k3s ctr images import /tmp/scannvnc.tar && rm /tmp/scannvnc.tar'
done
```

Bump the tag on each code change (`IfNotPresent` will not re-pull an existing tag).

## Install

```bash
export KUBECONFIG=~/.kube/kscsc-new.yaml
# Put your Shodan/Censys keys in an untracked overlay (see values.example.yaml)
helm upgrade --install scannvnc ./scannvnc \
  --namespace scannvnc --create-namespace -f my-values.yaml --wait
```

Populate the store immediately instead of waiting for the schedule:

```bash
kubectl create job -n scannvnc --from=cronjob/scannvnc-scannvnc-ingest ingest-now
kubectl logs -n scannvnc job/ingest-now
```

## Exposure on scannvnc.kscsc.local

Like every other app here, the hostname must be in **two** shared releases, or
DNS/TLS will not match. Both edits are append-only:

1. `coreDNS/values.yaml` → add `scannvnc.kscsc.local` under `hosts.envoy`
   → `helm upgrade coredns-custom ./coreDNS -n kube-system`
2. `envoy/values.yaml` → add `scannvnc.kscsc.local` under `certificate.dnsNames`
   → `helm upgrade envoy-resources ./envoy -n envoy-gateway-system`
   (re-issues the shared gateway cert; existing SANs are preserved)

Until then, reach it directly:

```bash
kubectl port-forward -n scannvnc deploy/scannvnc-scannvnc-dashboard 8000:8000
# http://localhost:8000
```

## Notes

- SQLite on a `ReadWriteOnce` local-path volume → dashboard is `replicas: 1`,
  `Recreate`; the ingest CronJob has a `podAffinity` to co-locate on the same
  node as the dashboard (it owns the volume).
- The dashboard filters by `protocol=` and `weak=1`; JSON at `/api/summary` and
  `/api/endpoints`.
- Weak-posture flags are derived only from search-engine metadata. The chart
  deploys **no** capability to connect to or authenticate against a discovered
  host.

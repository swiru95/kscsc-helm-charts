# ☸️ KSCSC Kubernetes Helm Charts

A curated collection of Helm charts for deploying security tools, AI infrastructure, PKI, and automation services on **K3s** (single-node, `192.168.95.50`).

Custom-configured charts designed for ease of use, stability, and security hardening — all TLS certificates are automatically issued by an in-cluster Certificate Authority.

---

## 📐 Architecture

```
Client ──DNS──▶ 192.168.95.50 ──▶ nginx ingress ──▶ Services
                                        │
                                   TLS certs from
                                        │
                        cert-manager ──ACME──▶ step-ca ──▶ KSCSC Intermediate CA ──▶ KSCSC Root CA
```

All `*.kscsc.local` DNS is resolved **in-cluster** via a custom CoreDNS server block pointing to the ingress controller's ClusterIP — ACME challenges never leave the cluster.

---

## 🚀 Chart Collection

### 🔐 PKI & Certificate Management
| Chart | Namespace | Description |
| :--- | :--- | :--- |
| **[step-ca](step-ca/)** | `step-ca` | Smallstep Certificate Authority — issues certs via ACME using your own intermediate CA |
| **[cluster-issuer](cluster-issuer/)** | `cert-manager` | cert-manager + ACME ClusterIssuer — auto-issues TLS certs for all Ingresses |
| **[coreDNS](coreDNS/)** | `kube-system` | Custom CoreDNS config — resolves `*.kscsc.local` to the ingress ClusterIP in-cluster |

### 🛡️ Security & Auditing
| Chart | Namespace | Description |
| :--- | :--- | :--- |
| **[BloodHound](bloodhound/)** | `bloodhound` | Active Directory attack path management (custom templates) |
| **[Falco](falco/)** | `falco` | Runtime threat detection for Kubernetes |
| **[OAuth2 Proxy](oauth2-proxy/)** | `oauth2-proxy` | Authentication proxy — protects services behind SSO |

### 🤖 AI & LLMs
| Chart | Namespace | Description |
| :--- | :--- | :--- |
| **[Ollama](ollama/)** | `ollama` | Run large language models locally (GPU-accelerated) |
| **[OpenUI](openui/)** | `openui` | Web UI for interacting with LLMs via Ollama |
| **[Splunk](splunk/)** | `splunk` | SIEM with integrated Ollama proxy for AI-assisted analysis |

### ⚡ Automation & Utilities
| Chart | Namespace | Description |
| :--- | :--- | :--- |
| **[n8n](n8n-hosting/kubernetes/n8n-helm/)** | `default` | Workflow automation platform |
| **[Actual Budget](actualbudget/)** | `actualbudget` | Privacy-focused local-first personal finance |

---

## 🌐 Ingress & TLS Status

All nginx ingresses are annotated with `cert-manager.io/cluster-issuer: "kscsc-ca-issuer"` and receive certificates signed by **KSCSC Intermediate CA** via the in-cluster step-ca ACME flow.

| Host | Chart | TLS |
| :--- | :--- | :--- |
| `ca.kscsc.local` | step-ca | ✅ Auto (cert-manager) |
| `actualbudget.kscsc.local` | actualbudget | ✅ Auto (cert-manager) |
| `auth.kscsc.local` | oauth2-proxy | ✅ Auto (cert-manager) |
| `ollama.kscsc.local` | ollama | ✅ Auto (cert-manager) |
| `openui.kscsc.local` | openui | ✅ Auto (cert-manager) |
| `splunk.kscsc.local` | splunk | ✅ Auto (cert-manager) |
| `n8n.kscsc.local` | n8n | ✅ Auto (cert-manager) |
| `bloodhound.kscsc.local` | bloodhound | ✅ Auto (cert-manager) |

---

## 🛠️ Usage

### Prerequisites

- **K3s** with nvidia GPU taint (`nvidia.com/gpu: present`) — all charts include the required toleration
- **Helm 3.x**
- DNS entries for `*.kscsc.local` pointing to `192.168.95.50` on your client machines (or use the cluster's CoreDNS for in-cluster resolution)

### Installation Order

The PKI stack should be deployed first, then the application charts:

```bash
# 1. CoreDNS custom config (in-cluster DNS for *.kscsc.local)
helm install coredns-custom ./coreDNS -n kube-system

# 2. step-ca (Certificate Authority)
helm install step-ca smallstep/step-certificates -n step-ca --create-namespace \
  -f ./step-ca/values.yaml

# 3. cert-manager CRDs (must exist before ClusterIssuer)
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.17.2/cert-manager.crds.yaml

# 4. cluster-issuer (cert-manager + ACME ClusterIssuer)
helm install cluster-issuer ./cluster-issuer -n cert-manager --create-namespace \
  --set cert-manager.crds.enabled=false

# 5. Application charts (any order)
helm install actualbudget community-charts/actualbudget -n actualbudget --create-namespace \
  -f ./actualbudget/values.yaml
helm install oauth2-proxy oauth2-proxy/oauth2-proxy -n oauth2-proxy --create-namespace \
  -f ./oauth2-proxy/values.yaml
helm install ollama ./ollama -n ollama --create-namespace
helm install openui ./openui -n openui --create-namespace
helm install splunk ./splunk -n splunk --create-namespace
helm install n8n ./n8n-hosting/kubernetes/n8n-helm -n default
```

### Issuing Certificates Manually

For services **outside** the cluster (e.g., Proxmox, NAS):

```bash
# Bootstrap step CLI (one-time)
step ca bootstrap --ca-url https://ca.kscsc.local \
  --fingerprint <ROOT_CA_FINGERPRINT>

# Issue a certificate (max 2160h / 90 days with default provisioner limits)
step ca certificate "proxmox.kscsc.local" proxmox.crt proxmox.key \
  --provisioner "<PROVISIONER_NAME>" \
  --provisioner-password-file <(echo -n '<PROVISIONER_PASSWORD>') \
  --not-after 2160h
```

### Trusting the CA on Client Machines

Install the **Root CA certificate** in your OS/browser trust store:

| OS / Browser | Command |
| :--- | :--- |
| **Linux (Debian/Ubuntu/Kali)** | `sudo cp root_ca.crt /usr/local/share/ca-certificates/kscsc-root-ca.crt && sudo update-ca-certificates` |
| **Chrome/Edge on Linux** | `certutil -d sql:$HOME/.pki/nssdb -A -t "C,," -n "KSCSC Root CA" -i root_ca.crt` |
| **Firefox** | Settings → Privacy & Security → Certificates → View Certificates → Authorities → Import |
| **Windows** | `certutil -addstore "Root" root_ca.crt` |
| **macOS** | `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain root_ca.crt` |

---

## ⚠️ Important Notes

- **GPU taint**: All nodes have `nvidia.com/gpu: present` taint — every chart includes the toleration. Don't forget it for any new deployments.
- **step-ca is a remote chart**: `step-ca/` only contains `values.yaml` — deploy with `smallstep/step-certificates` from the Helm repo, not `./step-ca`.
- **Key format**: step-ca requires **legacy OpenSSL encrypted PEM** (`Proc-Type: 4,ENCRYPTED`), not PKCS#8. See [step-ca/README.md](step-ca/README.md) for conversion instructions.
- **YAML `y` key gotcha**: JWK provisioner EC keys have a `y` field that YAML interprets as boolean `true` — use inline JSON format in values.
- **cert-manager CRDs**: Installed separately before the cluster-issuer chart (`cert-manager.crds.enabled=false` in values).
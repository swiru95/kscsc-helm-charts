# Step CA — Smallstep Certificate Authority

Deploys [Smallstep step-certificates](https://github.com/smallstep/certificates) as a private Certificate Authority in Kubernetes, capable of signing and managing X.509 certificates for both cluster-internal services and external infrastructure.

This configuration uses **your own intermediate CA** certificate and key (injected via Helm values), so the CA chains up to your existing PKI trust hierarchy.

## Architecture

```
┌─────────────────────┐
│   Your Root CA      │  (offline, not deployed)
│   (trust anchor)    │
└────────┬────────────┘
         │ signs
┌────────▼────────────┐
│ Intermediate CA     │  ◄── deployed in step-ca pod
│ (step-certificates) │
└────────┬────────────┘
         │ issues
┌────────▼────────────┐
│  Leaf Certificates  │  (servers, clients, devices)
└─────────────────────┘
```

## Prerequisites

- Kubernetes 1.19+
- Helm 3.x
- [`step` CLI](https://smallstep.com/docs/step-cli/installation) (for generating config and interacting with the CA)
- Your **root CA certificate** (PEM)
- Your **intermediate CA certificate** (PEM), signed by the root CA
- Your **intermediate CA private key** (encrypted PEM)
- The **password** that decrypts the intermediate CA key

## Quick Start

### 1. Add the Smallstep Helm repo

```bash
helm repo add smallstep https://smallstep.github.io/helm-charts/
helm repo update
```

### 2. Generate a provisioner key (optional — if you want JWK provisioner)

If you only need ACME, you can skip this and remove the JWK provisioner from `values.yaml`.

```bash
# Generate a JWK provisioner key pair
step crypto jwk create provisioner.pub.json provisioner.key.json \
  --kty EC --crv P-384 --use sig

# Encrypt the private key
step crypto jwe encrypt --alg PBES2-HS384+A192KW provisioner.key.json
```

Then update the `inject.config.files.ca.json.authority.provisioners` JWK entry in `values.yaml` with the generated key material.

### 3. Prepare secrets

#### Intermediate CA key format

step-ca requires the intermediate CA private key in **legacy OpenSSL encrypted PEM** format (`Proc-Type: 4,ENCRYPTED` / `DEK-Info` headers). It does **not** support PKCS#8 encrypted keys (`-----BEGIN ENCRYPTED PRIVATE KEY-----`).

Expected format:
```
-----BEGIN EC PRIVATE KEY-----
Proc-Type: 4,ENCRYPTED
DEK-Info: AES-256-CBC,<hex-iv>

<base64-encoded encrypted key data>
-----END EC PRIVATE KEY-----
```

If your key is in PKCS#8 format (`-----BEGIN ENCRYPTED PRIVATE KEY-----`), convert it:

```bash
# 1. Decrypt the PKCS#8 key (will prompt for password)
openssl pkey -in intermediate.key.pem -out intermediate_plain.key

# 2. Re-encrypt in legacy OpenSSL format
openssl ec -in intermediate_plain.key -aes256 -out intermediate_legacy.key
# → enter the same password you'll use for ca_password

# 3. Remove the plaintext key
rm intermediate_plain.key
```

If your key is unencrypted (`-----BEGIN EC PRIVATE KEY-----` without `Proc-Type` headers), encrypt it:

```bash
openssl ec -in intermediate_plain.key -aes256 -out intermediate_legacy.key
```

Then paste the contents of `intermediate_legacy.key` into `inject.secrets.x509.intermediate_ca_key` in `values.yaml`.

#### Passwords and fingerprint

```bash
# Base64-encode your CA key password
echo -n "your-ca-key-password" | base64
# → put this in inject.secrets.ca_password

# Base64-encode your provisioner password
echo -n "your-provisioner-password" | base64
# → put this in inject.secrets.provisioner_password

# Get your root CA fingerprint
step certificate fingerprint root_ca.crt
# → put this in inject.config.files.defaults.json.fingerprint
```

### 4. Fill in values.yaml

Edit `values.yaml` and replace all `REPLACE_WITH_*` placeholders:

| Placeholder | Description |
|---|---|
| `REPLACE_WITH_YOUR_ROOT_CA_CERTIFICATE` | Your root CA certificate in PEM format |
| `REPLACE_WITH_YOUR_INTERMEDIATE_CA_CERTIFICATE` | Your intermediate CA certificate in PEM format |
| `REPLACE_WITH_YOUR_ENCRYPTED_INTERMEDIATE_CA_KEY` | Your encrypted intermediate CA private key in PEM |
| `REPLACE_WITH_BASE64_ENCODED_CA_PASSWORD` | `echo -n "password" \| base64` |
| `REPLACE_WITH_BASE64_ENCODED_PROVISIONER_PASSWORD` | `echo -n "password" \| base64` |
| `REPLACE_WITH_ROOT_CA_FINGERPRINT` | `step certificate fingerprint root_ca.crt` |
| `REPLACE_WITH_ENCRYPTED_JWK_KEY` | JWK encrypted key (if using JWK provisioner) |
| `REPLACE_WITH_KID`, `_X`, `_Y` | JWK public key material (if using JWK provisioner) |

### 5. Create the namespace and deploy

```bash
kubectl create namespace step-ca

helm install step-ca smallstep/step-certificates \
  -n step-ca \
  -f values.yaml
```

### 6. Verify the deployment

```bash
# Check pods
kubectl -n step-ca get pods

# Check logs
kubectl -n step-ca logs deploy/step-ca-step-certificates

# Test health endpoint (from within cluster)
kubectl -n step-ca run curl --rm -it --image=curlimages/curl -- \
  curl -sk https://step-ca-step-certificates.step-ca.svc.cluster.local/health
```

## Accessing the CA

### From inside the cluster

The CA is available at:
```
https://step-ca-step-certificates.step-ca.svc.cluster.local
```

### From outside the cluster

With the Ingress enabled, configure DNS for `ca.kscsc.local` to point to your ingress controller, then:

```bash
# Bootstrap the step CLI to trust the CA
step ca bootstrap --ca-url https://ca.kscsc.local \
  --fingerprint <ROOT_CA_FINGERPRINT>

# Verify
step ca health --ca-url https://ca.kscsc.local
```

## Requesting Certificates

### Via ACME protocol (automated)

The ACME provisioner is enabled, allowing tools like `certbot`, `step`, or cert-manager to request certs automatically:

```bash
# Request a certificate using step CLI + ACME
step ca certificate myserver.kscsc.local server.crt server.key \
  --provisioner acme \
  --ca-url https://ca.kscsc.local \
  --root root_ca.crt

# Or using certbot (standalone mode)
certbot certonly --standalone \
  --server https://ca.kscsc.local/acme/acme/directory \
  -d myserver.kscsc.local
```

### Via step CLI (manual / JWK provisioner)

```bash
step ca certificate myserver.kscsc.local server.crt server.key \
  --provisioner admin \
  --ca-url https://ca.kscsc.local \
  --root root_ca.crt
```

### Via cert-manager (Kubernetes-native)

Install [step-issuer](https://github.com/smallstep/step-issuer) to integrate with cert-manager:

```bash
helm install step-issuer smallstep/step-issuer
```

Then create a `StepClusterIssuer` or `StepIssuer` resource pointing to your CA.

## Distributing Trust

For non-cluster clients to trust certificates issued by this CA, install your **root CA certificate** in their trust stores:

```bash
# Linux (Debian/Ubuntu)
sudo cp root_ca.crt /usr/local/share/ca-certificates/kscsc-root-ca.crt
sudo update-ca-certificates

# macOS
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain root_ca.crt

# Windows (PowerShell as Admin)
Import-Certificate -FilePath root_ca.crt -CertStoreLocation Cert:\LocalMachine\Root
```

## Configuration Reference

| Parameter | Description | Default |
|---|---|---|
| `inject.config.files.ca.json.dnsNames` | DNS SANs for the CA certificate | `ca.kscsc.local, ...svc.cluster.local, 127.0.0.1` |
| `inject.config.files.ca.json.authority.claims.maxTLSCertDuration` | Max certificate lifetime | `2160h` (90 days) |
| `inject.config.files.ca.json.authority.claims.defaultTLSCertDuration` | Default certificate lifetime | `720h` (30 days) |
| `ca.db.size` | Database PVC size | `10Gi` |
| `service.type` | Kubernetes service type | `ClusterIP` |
| `service.port` | External service port | `443` |
| `ingress.enabled` | Enable ingress | `true` |
| `ingress.hosts[0].host` | Ingress hostname | `ca.kscsc.local` |

For the full list of parameters, see the [upstream chart documentation](https://artifacthub.io/packages/helm/smallstep/step-certificates).

## Upgrading

```bash
helm repo update
helm upgrade step-ca smallstep/step-certificates -n step-ca -f values.yaml
```

## Uninstalling

```bash
helm uninstall step-ca -n step-ca
# Optionally remove the PVC (will delete the CA database)
kubectl -n step-ca delete pvc --all
kubectl delete namespace step-ca
```

## Troubleshooting

```bash
# Check pod status and events
kubectl -n step-ca describe pod -l app.kubernetes.io/name=step-certificates

# View CA logs
kubectl -n step-ca logs -l app.kubernetes.io/name=step-certificates -f

# Verify the CA certificate chain
step certificate inspect --short root_ca.crt
step certificate inspect --short intermediate_ca.crt
step certificate verify intermediate_ca.crt --roots root_ca.crt

# Test CA connectivity
curl -sk https://ca.kscsc.local/health
```

### Common issues

| Issue | Cause | Fix |
|---|---|---|
| Pod CrashLoopBackOff | Wrong CA password or malformed key | Verify password decrypts the key: `step crypto key inspect intermediate_ca_key` |
| `x509: certificate signed by unknown authority` | Root CA not trusted by client | Install root CA in client trust store |
| ACME fails with `bad nonce` | Clock skew between client and CA | Sync NTP on all nodes |
| Ingress returns 502 | Backend protocol mismatch | Ensure `nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"` is set |

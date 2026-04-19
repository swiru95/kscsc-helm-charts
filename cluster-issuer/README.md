# Cluster Issuer — cert-manager + ACME ClusterIssuer (step-ca)

Installs [cert-manager](https://cert-manager.io/) as a dependency and creates an ACME `ClusterIssuer` that obtains certificates from the in-cluster [step-ca](../step-ca/) instance. No raw CA keys are needed — cert-manager talks to step-ca over ACME, keeping key material in one place.

```
Ingress ──annotation──▶ cert-manager ──ACME──▶ step-ca ──signs with──▶ Intermediate CA
```

## Prerequisites

- Kubernetes 1.19+
- Helm 3.x
- **step-ca** deployed and healthy (see [../step-ca](../step-ca/))
- ACME provisioner enabled on step-ca

## Quick Start

### 1. Build chart dependencies

```bash
cd cluster-issuer
helm dependency build
```

### 2. Review values.yaml

The defaults point to the in-cluster step-ca service. Adjust if your step-ca release name or namespace differs:

| Field | Description | Default |
|---|---|---|
| `clusterIssuer.server` | step-ca ACME endpoint URL | `https://step-ca-step-certificates.step-ca.svc.cluster.local/acme/acme/directory` |
| `clusterIssuer.email` | ACME registration email | `contact@kscsc.online` |
| `clusterIssuer.skipTLSVerify` | Skip TLS verification for step-ca | `true` |

### 3. Deploy

```bash
helm install cluster-issuer ./cluster-issuer \
  -n cert-manager --create-namespace
```

### 4. Verify

```bash
# Check cert-manager pods
kubectl -n cert-manager get pods

# Check ClusterIssuer status
kubectl get clusterissuer kscsc-ca-issuer
```

The `READY` column should show `True`.

## Usage

### Annotate an Ingress

Add this annotation to any Ingress to get a TLS cert automatically:

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: "kscsc-ca-issuer"
spec:
  tls:
    - hosts:
        - myapp.kscsc.local
      secretName: myapp-tls
```

### Create a Certificate resource

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: proxmox-cert
  namespace: default
spec:
  secretName: proxmox-tls
  issuerRef:
    name: kscsc-ca-issuer
    kind: ClusterIssuer
  dnsNames:
    - proxmox.kscsc.local
  duration: 2160h    # 90 days
  renewBefore: 360h  # renew 15 days before expiry
```

## TLS Verification

By default `skipTLSVerify: true` is set because step-ca serves a certificate signed by our own CA, which cert-manager doesn't trust out of the box.

To use proper TLS verification instead:

1. Set `clusterIssuer.skipTLSVerify: false`
2. Paste your root CA certificate into `ca.crt` in `values.yaml`

## Upgrading

```bash
helm dependency update cluster-issuer
helm upgrade cluster-issuer ./cluster-issuer -n cert-manager
```

## Uninstalling

```bash
helm uninstall cluster-issuer -n cert-manager
```

## Configuration

| Parameter | Description | Default |
|---|---|---|
| `clusterIssuer.name` | Name of the ClusterIssuer | `kscsc-ca-issuer` |
| `clusterIssuer.server` | step-ca ACME directory URL | `https://step-ca-step-certificates.step-ca.svc.cluster.local/acme/acme/directory` |
| `clusterIssuer.email` | ACME registration email | `contact@kscsc.online` |
| `clusterIssuer.skipTLSVerify` | Skip TLS verification for step-ca | `true` |
| `ca.crt` | Root CA certificate for TLS verification (when `skipTLSVerify: false`) | — |
| `cert-manager.*` | All cert-manager subchart values | See [cert-manager docs](https://artifacthub.io/packages/helm/cert-manager/cert-manager) |

# nvidia-device-plugin

Exposes NVIDIA GPUs as Kubernetes resources and taints the node with `nvidia.com/gpu: present`.

Currently running: **v0.18.0** (Helm-managed, `nvidia-device-plugin` namespace, 132d).

## Install

```bash
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm repo update

helm upgrade --install nvidia-device-plugin nvdp/nvidia-device-plugin \
  --version 0.18.0 \
  -n nvidia-device-plugin --create-namespace \
  -f values.yaml
```

## Note

Installing this plugin will taint the node with `nvidia.com/gpu: present NoSchedule`.
All workloads that need to run on this node must include the toleration:

```yaml
tolerations:
  - key: "nvidia.com/gpu"
    operator: "Exists"
    effect: "NoSchedule"
```

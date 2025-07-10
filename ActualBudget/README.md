Installation:

```bash
helm repo add community-charts https://community-charts.github.io/helm-charts
helm repo update
helm install my-actualbudget community-charts/actualbudget -n actualbudget -f values.yaml
```
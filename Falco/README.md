## Instalaltion

```
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update
helm install --replace falco --namespace falco --create-namespace -f values.yaml falcosecurity/falco
```
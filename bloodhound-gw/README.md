# bloodhound-gw

Envoy Gateway routing for BloodHound.

This chart deliberately holds ONLY the HTTPRoutes. BloodHound itself comes from the local
`bloodhound` chart — see README.md for the install order.

The upstream chart only knows how to emit an Ingress, and this cluster has no Ingress controller:
Envoy Gateway terminates TLS at 192.168.95.51 and routes by Gateway API HTTPRoute. So upstream's
`bloodhound.ingress` stays disabled and the route lives here instead, matching how openvas and
step-ca are wired.

## Install

```sh
helm upgrade --install bloodhound "$CHARTS/bloodhound" -n bloodhound --create-namespace \
  -f "$V/bloodhound__bloodhound.yaml" --wait
helm upgrade --install bloodhound-gw "$CHARTS/bloodhound-gw" -n bloodhound \
  -f "$V/bloodhound__bloodhound-gw.yaml"
```

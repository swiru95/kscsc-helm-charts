{{- define "myfinance.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{- define "myfinance.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "myfinance.backendName" -}}
{{- printf "%s-backend" (include "myfinance.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "myfinance.frontendName" -}}
{{- printf "%s-frontend" (include "myfinance.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* The database's in-cluster FQDN. The server certificate is issued for this
     exact name and clients verify against it, so it must be derived, never
     typed twice. */}}
{{- define "myfinance.postgresHost" -}}
{{- printf "%s-postgres.%s.svc.cluster.local" (include "myfinance.fullname" .) .Release.Namespace -}}
{{- end -}}

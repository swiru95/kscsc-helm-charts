{{- define "scannvnc.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{- define "scannvnc.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "scannvnc.dashboardName" -}}
{{- printf "%s-dashboard" (include "scannvnc.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Name of the Secret holding the search-engine API keys. */}}
{{- define "scannvnc.secretName" -}}
{{- if .Values.searchEngines.existingSecret -}}
{{- .Values.searchEngines.existingSecret -}}
{{- else -}}
{{- printf "%s-search" (include "scannvnc.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "scannvnc.pvcName" -}}
{{- if .Values.pvc.name -}}
{{- .Values.pvc.name -}}
{{- else -}}
{{- printf "%s-data" (include "scannvnc.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "openui.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{- define "openui.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
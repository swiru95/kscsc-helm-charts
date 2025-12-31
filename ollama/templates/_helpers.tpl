{{- define "ollama.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{- define "ollama.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- /* Backwards compatibility helpers referencing old name */ -}}
{{- define "hello-pvc.name" -}}
{{- include "ollama.name" . -}}
{{- end -}}

{{- define "hello-pvc.fullname" -}}
{{- include "ollama.fullname" . -}}
{{- end -}}

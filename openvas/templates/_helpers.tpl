{{- define "openvas.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{- define "openvas.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- /*
Resolve a container image from the shared registry plus a per-component tag.
Usage: include "openvas.image" (dict "root" $ "tag" .Values.image.tags.gvmd "repo" "gvmd")
*/ -}}
{{- define "openvas.image" -}}
{{- printf "%s/%s:%s" .root.Values.image.registry .repo .tag -}}
{{- end -}}

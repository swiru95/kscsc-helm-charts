{{/*
Expand the name of the chart.
*/}}
{{- define "news-bot.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a fully qualified app name.
*/}}
{{- define "news-bot.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "news-bot.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: {{ include "news-bot.name" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}

{{/*
Selector labels for news-bot pipeline
*/}}
{{- define "news-bot.selectorLabels" -}}
app.kubernetes.io/name: {{ include "news-bot.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Selector labels for linkedin-feeder
*/}}
{{- define "news-bot.linkedinSelectorLabels" -}}
app.kubernetes.io/name: {{ include "news-bot.name" . }}-linkedin
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Secret name (created or existing)
*/}}
{{- define "news-bot.secretName" -}}
{{- if .Values.secrets.existingSecret }}
{{- .Values.secrets.existingSecret }}
{{- else }}
{{- include "news-bot.fullname" . }}-secrets
{{- end }}
{{- end }}

{{/*
PVC name (created or existing)
*/}}
{{- define "news-bot.pvcName" -}}
{{- if .Values.persistence.existingClaim }}
{{- .Values.persistence.existingClaim }}
{{- else }}
{{- include "news-bot.fullname" . }}-data
{{- end }}
{{- end }}

{{/*
Feeds ConfigMap name (inline-created or existing)
*/}}
{{- define "news-bot.feedsConfigMapName" -}}
{{- if .Values.feeds.existingConfigMap }}
{{- .Values.feeds.existingConfigMap }}
{{- else }}
{{- include "news-bot.fullname" . }}-feeds
{{- end }}
{{- end }}

{{/*
Pod template: common nodeSelector / tolerations / affinity
*/}}
{{- define "news-bot.scheduling" -}}
{{- with .Values.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

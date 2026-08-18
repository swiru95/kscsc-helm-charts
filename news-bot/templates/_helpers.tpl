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
LLM server base URL. The feeder wants the host root (it appends /v1/chat/completions
and /v1/models itself), while the pipeline's config.yaml wants the full endpoint —
so derive the former from the latter and keep a single source of truth in values.
*/}}
{{- define "news-bot.llmHost" -}}
{{- .Values.ollama.apiUrl | trimSuffix "/v1/chat/completions" | trimSuffix "/" }}
{{- end }}

{{/*
LLM API key env. Both entry points read OLLAMA_API_KEY and add the "Bearer "
themselves. Optional so the chart still renders before the key is added to the
Secret; without it llama-server answers 401.
*/}}
{{- define "news-bot.llmAuthEnv" -}}
{{- if .Values.ollama.apiKeySecretKey }}
- name: OLLAMA_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "news-bot.secretName" . }}
      key: {{ .Values.ollama.apiKeySecretKey }}
      optional: true
{{- end }}
{{- end }}

{{/*
Trusted CA: init container that appends the private root to the image's CA
bundle. Appends rather than replaces — the pipeline also fetches RSS over
public HTTPS, which still needs the Mozilla roots. Shared by both CronJobs.
*/}}
{{- define "news-bot.trustedCA.initContainer" -}}
- name: ca-bundle
  image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  command:
    - sh
    - -c
    - cat /etc/ssl/certs/ca-certificates.crt /kscsc-ca/root_ca.crt > /ca-bundle/ca-certificates.crt
  securityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop: ["ALL"]
  volumeMounts:
    - name: kscsc-ca
      mountPath: /kscsc-ca
      readOnly: true
    - name: ca-bundle
      mountPath: /ca-bundle
{{- end }}

{{/*
Trusted CA: volumes, mounts and env for the application container.
*/}}
{{- define "news-bot.trustedCA.volumes" -}}
- name: kscsc-ca
  configMap:
    name: {{ include "news-bot.fullname" . }}-trusted-ca
- name: ca-bundle
  emptyDir:
    sizeLimit: 8Mi
{{- end }}

{{- define "news-bot.trustedCA.volumeMounts" -}}
- name: ca-bundle
  mountPath: /etc/ssl/certs/ca-certificates.crt
  subPath: ca-certificates.crt
  readOnly: true
{{- end }}

{{- define "news-bot.trustedCA.env" -}}
- name: SSL_CERT_FILE
  value: /etc/ssl/certs/ca-certificates.crt
- name: REQUESTS_CA_BUNDLE
  value: /etc/ssl/certs/ca-certificates.crt
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

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

{{/*
Where autocert's bootstrapper drops the pair, as the two entry points read it.
Both read OLLAMA_CLIENT_* from the environment; the pipeline also accepts
llm.client_cert / llm.client_key in config.yaml, but env keeps the two paths
defined in exactly one place.
*/}}
{{- define "news-bot.autocert.name" -}}
{{- /* Defaulted, never nil: a release upgraded with --reuse-values reuses the
       old values verbatim and never sees a new chart default, which would
       otherwise render `autocert.step.sm/name: null` and silently get no
       certificate. Must match a SAN key in llama-server's role_map, which is
       compared byte-for-byte. */ -}}
{{- .Values.autocert.name | default (printf "%s.%s.svc.cluster.local" (include "news-bot.fullname" .) .Release.Namespace) }}
{{- end }}

{{- define "news-bot.autocert.mountPath" -}}
{{- .Values.autocert.mountPath | default "/var/run/autocert.step.sm" }}
{{- end }}

{{- define "news-bot.autocert.env" -}}
- name: OLLAMA_CLIENT_CERT
  value: {{ printf "%s/site.crt" (include "news-bot.autocert.mountPath" .) | quote }}
- name: OLLAMA_CLIENT_KEY
  value: {{ printf "%s/site.key" (include "news-bot.autocert.mountPath" .) | quote }}
{{- end }}

{{/*
Shell prologue that stops autocert's renewer when the job's work is done.

autocert injects a renewer sidecar that runs forever, and a Job is only
complete once EVERY container has exited. Without this the job hangs until
activeDeadlineSeconds and is then marked FAILED, having done all its work.
Installed as an EXIT trap so the early-exit paths are covered too - the
LinkedIn feeder returns early when there is nothing new to post.

Requires shareProcessNamespace: true on the pod, and works because the
injected renewer inherits the pod's runAsUser (999), so the same UID may
signal it. Measured against this cluster on 2026-09-18.
*/}}
{{- define "news-bot.autocert.teardown" -}}
_stop_renewer() {
  python3 <<'PYEOF'
import os, signal, time
# The renewer starts in parallel with this container, so a run that finishes in
# seconds can reach here before "step" exists. Wait for it rather than leaving
# the sidecar behind and hanging the Job.
deadline = time.time() + 60
me = {os.getpid(), os.getppid()}
target = None
while time.time() < deadline and target is None:
    for pid in filter(str.isdigit, os.listdir("/proc")):
        if int(pid) in me:
            continue
        try:
            argv0 = open(f"/proc/{pid}/cmdline", "rb").read().split(b"\0")[0]
        except OSError:
            continue
        # The sidecar runs `step ca renew --daemon`, so argv[0] is "step" - not
        # "autocert-renewer" as the container is named. Matching argv[0] only:
        # matching the whole cmdline would also match the shell running this.
        if os.path.basename(argv0.decode("utf8", "replace")) == "step":
            target = int(pid)
            break
    if target is None:
        time.sleep(1)
if target is not None:
    try:
        os.kill(target, signal.SIGTERM)
    except (PermissionError, ProcessLookupError):
        pass
PYEOF
}
trap _stop_renewer EXIT
{{- end }}

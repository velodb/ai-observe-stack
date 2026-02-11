{{/*
Expand the name of the chart.
*/}}
{{- define "aiobs.name" -}}
{{- default .Chart.Name .Values.global.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "aiobs.fullname" -}}
{{- if .Values.global.fullnameOverride }}
{{- .Values.global.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.global.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "aiobs.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "aiobs.labels" -}}
helm.sh/chart: {{ include "aiobs.chart" . }}
{{ include "aiobs.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "aiobs.selectorLabels" -}}
app.kubernetes.io/name: {{ include "aiobs.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* ==========================================================================
   Doris Connection Helpers
   ========================================================================== */}}

{{/*
Get Doris FE host (MySQL protocol)
Doris Operator creates Service with name: <cluster-name>-fe-service
*/}}
{{- define "aiobs.doris.host" -}}
{{- if eq .Values.doris.mode "external" -}}
{{ required "doris.external.host is required when doris.mode is external" .Values.doris.external.host }}
{{- else -}}
{{ include "aiobs.doris.clusterName" . }}-fe-service
{{- end -}}
{{- end }}

{{/*
Get Doris FE MySQL port
*/}}
{{- define "aiobs.doris.port" -}}
{{- if eq .Values.doris.mode "external" -}}
{{ .Values.doris.external.port | default 9030 }}
{{- else -}}
9030
{{- end -}}
{{- end }}

{{/*
Get Doris FE HTTP port (for Web UI and Stream Load routing)
K8s deployed Doris can write data directly through FE HTTP port 8030
*/}}
{{- define "aiobs.doris.feHttpPort" -}}
{{- if eq .Values.doris.mode "external" -}}
{{ .Values.doris.external.feHttpPort | default 8030 }}
{{- else -}}
8030
{{- end -}}
{{- end }}

{{/*
Get Doris BE HTTP port (for direct Stream Load to BE)
Used in advanced scenarios where direct BE access is needed
*/}}
{{- define "aiobs.doris.beHttpPort" -}}
{{- if eq .Values.doris.mode "external" -}}
{{ .Values.doris.external.beHttpPort | default 8040 }}
{{- else -}}
8040
{{- end -}}
{{- end }}

{{/*
Get Doris FE HTTP endpoint (for OTel collector Stream Load)
K8s deployed Doris: use FE HTTP port 8030 directly (FE will route to BE)
*/}}
{{- define "aiobs.doris.feHttpEndpoint" -}}
{{- if eq .Values.doris.mode "external" -}}
http://{{ include "aiobs.doris.host" . }}:{{ include "aiobs.doris.feHttpPort" . }}
{{- else -}}
http://{{ include "aiobs.doris.clusterName" . }}-fe-service:8030
{{- end -}}
{{- end }}

{{/*
Get Doris BE HTTP endpoint (for direct Stream Load to BE)
*/}}
{{- define "aiobs.doris.beHttpEndpoint" -}}
{{- if eq .Values.doris.mode "external" -}}
http://{{ include "aiobs.doris.host" . }}:{{ include "aiobs.doris.beHttpPort" . }}
{{- else -}}
http://{{ include "aiobs.doris.clusterName" . }}-be-service:8040
{{- end -}}
{{- end }}

{{/*
Get Doris MySQL endpoint (host:port)
*/}}
{{- define "aiobs.doris.mysqlEndpoint" -}}
{{ include "aiobs.doris.host" . }}:{{ include "aiobs.doris.port" . }}
{{- end }}

{{/*
Get Doris username
*/}}
{{- define "aiobs.doris.user" -}}
{{- if eq .Values.doris.mode "external" -}}
{{ .Values.doris.external.user | default "root" }}
{{- else -}}
root
{{- end -}}
{{- end }}

{{/*
Get Doris password
Note: Returns empty string for internal mode or when using existingSecret
*/}}
{{- define "aiobs.doris.password" -}}
{{- if eq .Values.doris.mode "external" -}}
{{- if not .Values.doris.external.existingSecret -}}
{{ .Values.doris.external.password | default "" }}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Get Doris database name
*/}}
{{- define "aiobs.doris.database" -}}
{{ .Values.doris.database | default "otel" }}
{{- end }}

{{/*
Check if using external secret for Doris credentials
*/}}
{{- define "aiobs.doris.useExistingSecret" -}}
{{- if and (eq .Values.doris.mode "external") .Values.doris.external.existingSecret -}}
true
{{- else -}}
false
{{- end -}}
{{- end }}

{{/* ==========================================================================
   Component Name Helpers
   ========================================================================== */}}

{{/*
OTel Collector full name
*/}}
{{- define "aiobs.otel.fullname" -}}
{{ include "aiobs.fullname" . }}-otel-collector
{{- end }}

{{/*
Grafana full name
*/}}
{{- define "aiobs.grafana.fullname" -}}
{{ include "aiobs.fullname" . }}-grafana
{{- end }}

{{/*
Doris cluster full name
*/}}
{{- define "aiobs.doris.clusterName" -}}
{{ include "aiobs.fullname" . }}-doris
{{- end }}

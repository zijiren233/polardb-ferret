{{/*
Expand the name of the chart.
*/}}
{{- define "polardb-for-postgresql.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "polardb-for-postgresql.fullname" -}}
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
Create chart name and version as used by the chart label.
*/}}
{{- define "polardb-for-postgresql.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "polardb-for-postgresql.labels" -}}
helm.sh/chart: {{ include "polardb-for-postgresql.chart" . }}
app.kubernetes.io/part-of: polardb-for-postgresql
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels shared by all components.
*/}}
{{- define "polardb-for-postgresql.selectorLabels" -}}
app.kubernetes.io/name: {{ include "polardb-for-postgresql.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
PolarDB component names and labels.
*/}}
{{- define "polardb-for-postgresql.polardbName" -}}
{{- printf "%s-polardb" (include "polardb-for-postgresql.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "polardb-for-postgresql.polardbServiceName" -}}
{{- include "polardb-for-postgresql.polardbName" . }}
{{- end }}

{{- define "polardb-for-postgresql.polardbHeadlessServiceName" -}}
{{- printf "%s-headless" (include "polardb-for-postgresql.polardbName" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "polardb-for-postgresql.polardbReplicaServiceName" -}}
{{- printf "%s-replica" (include "polardb-for-postgresql.polardbName" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "polardb-for-postgresql.polardbServiceAccountName" -}}
{{- include "polardb-for-postgresql.polardbName" . }}
{{- end }}

{{- define "polardb-for-postgresql.polardbLeaseName" -}}
{{- if .Values.ha.leaseName }}
{{- .Values.ha.leaseName | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-primary" (include "polardb-for-postgresql.polardbName" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "polardb-for-postgresql.polardbSelectorLabels" -}}
{{ include "polardb-for-postgresql.selectorLabels" . }}
app.kubernetes.io/component: polardb
{{- end }}

{{- define "polardb-for-postgresql.polardbLabelSelector" -}}
app.kubernetes.io/name={{ include "polardb-for-postgresql.name" . }},app.kubernetes.io/instance={{ .Release.Name }},app.kubernetes.io/component=polardb
{{- end }}

{{- define "polardb-for-postgresql.polardbLabels" -}}
{{ include "polardb-for-postgresql.labels" . }}
{{ include "polardb-for-postgresql.polardbSelectorLabels" . }}
{{- end }}

{{/*
FerretDB component names and labels.
*/}}
{{- define "polardb-for-postgresql.ferretdbName" -}}
{{- printf "%s-ferretdb" (include "polardb-for-postgresql.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "polardb-for-postgresql.ferretdbSelectorLabels" -}}
{{ include "polardb-for-postgresql.selectorLabels" . }}
app.kubernetes.io/component: ferretdb
{{- end }}

{{- define "polardb-for-postgresql.ferretdbLabels" -}}
{{ include "polardb-for-postgresql.labels" . }}
{{ include "polardb-for-postgresql.ferretdbSelectorLabels" . }}
{{- end }}

{{/*
Secret name.
*/}}
{{- define "polardb-for-postgresql.secretName" -}}
{{- if .Values.auth.existingSecret }}
{{- .Values.auth.existingSecret }}
{{- else }}
{{- printf "%s-auth" (include "polardb-for-postgresql.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

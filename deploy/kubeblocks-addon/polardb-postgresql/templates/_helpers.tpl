{{/*
Expand chart name.
*/}}
{{- define "polardb-postgresql.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create chart name and version label.
*/}}
{{- define "polardb-postgresql.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "polardb-postgresql.labels" -}}
helm.sh/chart: {{ include "polardb-postgresql.chart" . }}
{{ include "polardb-postgresql.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "polardb-postgresql.selectorLabels" -}}
app.kubernetes.io/name: {{ include "polardb-postgresql.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
KubeBlocks API annotation.
*/}}
{{- define "polardb-postgresql.apiVersion" -}}
kubeblocks.io/crd-api-version: apps.kubeblocks.io/v1
{{- end }}

{{/*
Common annotations.
*/}}
{{- define "polardb-postgresql.annotations" -}}
{{ include "polardb-postgresql.apiVersion" . }}
{{- end }}

{{/*
ComponentDefinition name. Keep the chart version suffix to allow safe addon upgrades.
*/}}
{{- define "polardb-postgresql.cmpdName" -}}
polardb-postgresql-17-{{ .Chart.Version }}
{{- end -}}

{{/*
ComponentDefinition compatibility pattern used by ComponentVersion.
*/}}
{{- define "polardb-postgresql.cmpdRegexpPattern" -}}
^polardb-postgresql-17-
{{- end -}}

{{/*
Script ConfigMap name.
*/}}
{{- define "polardb-postgresql.scriptsTplName" -}}
polardb-postgresql-scripts-{{ .Chart.Version }}
{{- end -}}

{{/*
Image reference.
*/}}
{{- define "polardb-postgresql.image" -}}
{{- $registry := .Values.image.registry | default "docker.io" -}}
{{- printf "%s/%s:%s" $registry .Values.image.repository (.Values.image.tag | default .Chart.AppVersion) -}}
{{- end -}}

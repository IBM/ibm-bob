{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "rhbkOperator.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "rhbkOperator.labels" -}}
helm.sh/chart: {{ include "rhbkOperator.chart" . }}
{{ include "rhbkOperator.selectorLabels" . | indent 0}}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "rhbkOperator.selectorLabels" -}}
app.kubernetes.io/name: ibm-bob
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* Define unique service accounts for iteration*/}}
{{- define "rhbkOperator.serviceAccounts" -}}
  {{- $serviceAccounts := list -}}
  {{- range .Values.rhbkOperator.clusterPermissions }}
    {{- $serviceAccounts = append $serviceAccounts .serviceAccountName -}}
  {{- end }}
  {{- $serviceAccounts | uniq | toYaml }}
{{- end -}}

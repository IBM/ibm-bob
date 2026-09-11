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

{{/*
Create the image path for container images.
Usage: {{ include "image.operatorPrefix" }}
*/}}
{{- define "image.operatorPrefix" -}}
{{- print .Values.rhbkOperator.devImagePullPrefix | default .Values.global.imagePullPrefix | default "icr.io" -}}
{{- end }}

{{/*
Create the image path for container images.
Usage: {{ include "image.operandPrefix" }}
*/}}
{{- define "image.operandPrefix" -}}
{{- print .Values.rhbkOperator.devImagePullPrefix | default .Values.global.imagePullPrefix | default "cp.icr.io" -}}
{{- end }}

{{/* Define a watchNamespace template for iteration*/}}
{{- define "rhbkOperator.watchNamespaces" -}}
  {{- $list := initial list -}}
  {{- if .Values.global.operatorNamespace -}}
    {{- $list = append $list .Values.global.operatorNamespace -}}
  {{- end -}}
  {{- range $ns := .Values.global.tetheredNamespaces }}
    {{- $list = append $list $ns -}}
  {{- end }}
  {{- if .Values.global.instanceNamespace -}}
    {{- $list = append $list .Values.global.instanceNamespace -}}
  {{- end -}}
  {{- $list | toYaml -}}
{{- end -}}

{{/* Define unique service accounts for iteration*/}}
{{- define "rhbkOperator.serviceAccounts" -}}
  {{- $serviceAccounts := list -}}
  {{- range .Values.rhbkOperator.permissions }}
    {{- $serviceAccounts = append $serviceAccounts .serviceAccountName -}}
  {{- end }}
  {{- range .Values.rhbkOperator.clusterPermissions }}
    {{- $serviceAccounts = append $serviceAccounts .serviceAccountName -}}
  {{- end }}
  {{- $serviceAccounts | uniq | toYaml }}
{{- end -}}


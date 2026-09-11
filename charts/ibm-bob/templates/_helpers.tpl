{{/*
Create the image path for operator images.
Usage: {{ include "bob.image.operatorPrefix" }}
*/}}
{{- define "bob.image.operatorPrefix" -}}
{{- print (.Values.bob.devImagePullPrefix | default .Values.global.imagePullPrefix | default "icr.io") -}}
{{- end }}

{{/*
Create the image path for operand images.
Usage: {{ include "bob.image.operandPrefix" }}
*/}}
{{- define "bob.image.operandPrefix" -}}
{{- print (.Values.bob.devImagePullPrefix | default .Values.global.imagePullPrefix | default "cp.icr.io") -}}
{{- end }}


{{- define "cab.labels" -}}
app.kubernetes.io/part-of: cab-booking-system
app.kubernetes.io/managed-by: {{ .Release.Service | quote }}
app.kubernetes.io/instance: {{ .Release.Name | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | quote }}
{{- end }}

{{- define "cab.selectorLabels" -}}
app.kubernetes.io/name: {{ .name | quote }}
app.kubernetes.io/instance: {{ .root.Release.Name | quote }}
{{- end }}

{{- define "cab.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{ default "cab-booking-system" .Values.serviceAccount.name }}
{{- else -}}
{{ default "default" .Values.serviceAccount.name }}
{{- end -}}
{{- end }}

{{- define "cab.image" -}}
{{- $tag := default .root.Values.global.imageTag .image.tag -}}
{{- printf "%s/%s:%s" .root.Values.global.imageRegistry .image.repository $tag -}}
{{- end }}

{{- define "cab.envVars" -}}
{{- $secretName := .secretName -}}
{{- range $key, $value := .plain }}
- name: {{ $key }}
  value: {{ $value | quote }}
{{- end }}
{{- range $name, $key := .secret }}
- name: {{ $name }}
  valueFrom:
    secretKeyRef:
      name: {{ $secretName }}
      key: {{ $key }}
{{- end }}
{{- end }}

{{- define "cab.hookAnnotations" -}}
"helm.sh/hook": pre-install,pre-upgrade
"helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
"helm.sh/hook-weight": {{ .weight | quote }}
{{- end }}

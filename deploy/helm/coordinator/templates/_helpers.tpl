{{- define "coordinator.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "coordinator.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := include "coordinator.name" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "coordinator.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "coordinator.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: coordinator
{{- end -}}

{{- define "coordinator.selectorLabels" -}}
app.kubernetes.io/name: {{ include "coordinator.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: coordinator
{{- end -}}

{{- define "coordinator.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "coordinator.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "coordinator.image" -}}
{{- if not .Values.image.tag -}}
{{- fail "image.tag is required (git tag coordinator-v*)" -}}
{{- end -}}
{{- printf "%s:%s" .Values.image.repository .Values.image.tag -}}
{{- end -}}

{{- define "coordinator.headlessName" -}}
{{- printf "%s-headless" (include "coordinator.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "coordinator.storageClassName" -}}
{{- if .Values.persistence.storageClassName -}}
{{- .Values.persistence.storageClassName -}}
{{- else -}}
{{- printf "%s-userdata-retain" (include "coordinator.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "coordinator.secretName" -}}
{{- if .Values.externalSecret.enabled -}}
{{- .Values.externalSecret.targetName -}}
{{- else -}}
{{- required "secrets.existingSecret is required when externalSecret.enabled is false" .Values.secrets.existingSecret -}}
{{- end -}}
{{- end -}}

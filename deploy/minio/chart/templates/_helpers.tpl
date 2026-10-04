{{/* vim: set filetype=mustache: */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "minio.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "minio.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "minio.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified image reference for an image block from values.yaml, honoring the
optional per-image registry prefix.

Usage: {{ include "minio.imageRef" (dict "image" .Values.image) }}
*/}}
{{- define "minio.imageRef" -}}
{{- $img := .image -}}
{{- $reg := $img.registry | default "" | trimSuffix "/" -}}
{{- if $reg -}}
{{- printf "%s/%s:%s" $reg $img.repository $img.tag -}}
{{- else -}}
{{- printf "%s:%s" $img.repository $img.tag -}}
{{- end -}}
{{- end -}}

{{/*
Name of the headless Service that gives every server a stable DNS name.
Distributed MinIO builds its server list from these names.
*/}}
{{- define "minio.headlessName" -}}
{{- printf "%s-svc" (include "minio.fullname" .) -}}
{{- end -}}

{{/*
Name of the Secret that holds the root credentials.
*/}}
{{- define "minio.secretName" -}}
{{- if .Values.existingSecret -}}
{{- .Values.existingSecret -}}
{{- else -}}
{{- include "minio.fullname" . -}}
{{- end -}}
{{- end -}}

{{/*
Service account name.
*/}}
{{- define "minio.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "minio.fullname" .) .Values.serviceAccount.name | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Number of volumes each server gets. Guarded so a bad value cannot render a
cluster with zero drives.

Note: sprig's `default` treats 0 as empty, so it cannot be used here; an explicit
0 must fail rather than silently become 1.
*/}}
{{- define "minio.volumesPerServer" -}}
{{- $raw := .Values.volumesPerServer -}}
{{- if kindIs "invalid" $raw -}}
{{- $raw = 1 -}}
{{- end -}}
{{- $v := int $raw -}}
{{- if lt $v 1 -}}
{{- fail (printf "volumesPerServer must be >= 1, got %v" $raw) -}}
{{- end -}}
{{- $v -}}
{{- end -}}

{{/*
Total number of drives in the cluster. Distributed MinIO needs at least 4, so a
value below that is rejected at render time instead of failing at runtime.
*/}}
{{- define "minio.totalDrives" -}}
{{- $servers := int .Values.replicas -}}
{{- if lt $servers 1 -}}
{{- fail "replicas must be >= 1" -}}
{{- end -}}
{{- $vps := int (include "minio.volumesPerServer" .) -}}
{{- $total := mul $servers $vps -}}
{{- if and (eq .Values.mode "distributed") (lt $total 4) -}}
{{- fail (printf "distributed MinIO needs at least 4 drives, got %d (replicas=%d volumesPerServer=%d)" $total $servers $vps) -}}
{{- end -}}
{{- $total -}}
{{- end -}}

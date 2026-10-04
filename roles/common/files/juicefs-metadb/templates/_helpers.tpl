{{/* vim: set filetype=mustache: */}}
{{/*
Copyright 2026 Kube AI Hub.
*/}}

{{- define "juicefs-metadb.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "juicefs-metadb.fullname" -}}
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

{{- define "juicefs-metadb.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
The Secret holding the superuser password: either one the operator already
manages or the one this chart creates.
*/}}
{{- define "juicefs-metadb.secretName" -}}
{{- if .Values.auth.existingSecret -}}
{{- .Values.auth.existingSecret -}}
{{- else -}}
{{- include "juicefs-metadb.fullname" . -}}
{{- end -}}
{{- end -}}

{{/*
The Secret holding the backup object store credentials.
*/}}
{{- define "juicefs-metadb.backupSecretName" -}}
{{- if .Values.backup.s3.existingSecret -}}
{{- .Values.backup.s3.existingSecret -}}
{{- else -}}
{{- printf "%s-backup" (include "juicefs-metadb.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
The superuser password.

This is required rather than generated: the JuiceFS CSI driver stores the same
password in its own Secret, and two independent `randAlphaNum` calls would
produce two different values inside one render. The installer generates it once
and passes it to both charts.
*/}}
{{- define "juicefs-metadb.password" -}}
{{- if .Values.auth.password -}}
{{- .Values.auth.password -}}
{{- else -}}
{{- fail "auth.password must be set: the JuiceFS CSI driver Secret needs the same value. Generate one and pass it to both juicefs-metadb and juicefs." -}}
{{- end -}}
{{- end -}}

{{/*
Connection string the JuiceFS CSI driver stores in its volume credentials.
juicefs accepts postgres:// URLs as `metaurl`.
*/}}
{{- define "juicefs-metadb.metaurl" -}}
{{- $host := printf "%s.%s.svc" (include "juicefs-metadb.fullname" .) .Release.Namespace -}}
{{- $db := first .Values.databases -}}
{{- printf "postgres://%s:%s@%s:%v/%s" .Values.auth.username (include "juicefs-metadb.password" .) $host .Values.service.port $db -}}
{{- end -}}

{{/*
Fully qualified image reference for an image block from values.yaml.

A per-image `registry` wins; otherwise the chart-level `imageRegistry` applies.

Usage: {{ include "juicefs-metadb.imageRef" (dict "ctx" . "image" .Values.image) }}
*/}}
{{- define "juicefs-metadb.imageRef" -}}
{{- $img := .image -}}
{{- $reg := $img.registry | default "" -}}
{{- if not $reg -}}
{{- $reg = .ctx.Values.imageRegistry | default "" -}}
{{- end -}}
{{- $reg = $reg | trimSuffix "/" -}}
{{- if $reg -}}
{{- printf "%s/%s:%s" $reg $img.repository $img.tag -}}
{{- else -}}
{{- printf "%s:%s" $img.repository $img.tag -}}
{{- end -}}
{{- end -}}

{{/*
Refuse a JuiceFS StorageClass for the metadata volume.

The CSI driver cannot mount a volume until it can read the metadata database, so
a metadata database stored on JuiceFS can never come back up after a restart.
This catches the mistake at render time rather than during an outage.
*/}}
{{- define "juicefs-metadb.validateStorageClass" -}}
{{- $sc := .Values.persistence.storageClass | default "" | lower -}}
{{- if and .Values.persistence.enabled (contains "juicefs" $sc) -}}
{{- fail (printf "persistence.storageClass %q is a JuiceFS class: the metadata database cannot live on the storage it describes. Use local-static or another independent class." .Values.persistence.storageClass) -}}
{{- end -}}
{{- end -}}

{{- define "juicefs-metadb.labels" -}}
app.kubernetes.io/name: {{ include "juicefs-metadb.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: kube-ai-hub
app.kubernetes.io/component: juicefs-metadb
helm.sh/chart: {{ include "juicefs-metadb.chart" . }}
{{- end -}}

{{- define "juicefs-metadb.selectorLabels" -}}
app.kubernetes.io/name: {{ include "juicefs-metadb.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

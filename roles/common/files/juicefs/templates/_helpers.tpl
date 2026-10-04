{{/* vim: set filetype=mustache: */}}
{{/*
Copyright 2026 Kube AI Hub.
*/}}

{{- define "juicefs.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "juicefs.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride -}}
{{- end -}}

{{- define "juicefs.fullname" -}}
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

{{- define "juicefs.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
The CSI driver name. Fixed by the probe paths the kubelet expects; changing it
would orphan every volume.
*/}}
{{- define "juicefs.driverName" -}}
csi.juicefs.com
{{- end -}}

{{- define "juicefs.secretName" -}}
{{- printf "%s-secret" (include "juicefs.fullname" .) -}}
{{- end -}}

{{- define "juicefs.labels" -}}
app.kubernetes.io/name: {{ include "juicefs.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: kube-ai-hub
app.kubernetes.io/component: juicefs-csi
helm.sh/chart: {{ include "juicefs.chart" . }}
{{- end -}}

{{- define "juicefs.selectorLabels" -}}
app.kubernetes.io/name: {{ include "juicefs.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Fully qualified image reference for an image block from values.yaml.

A per-image `registry` wins; otherwise the chart-level `imageRegistry` applies.
That lets a site set one prefix for everything and still override a single image
that lives somewhere else.

Usage: {{ include "juicefs.imageRef" (dict "ctx" . "image" .Values.image) }}
*/}}
{{- define "juicefs.imageRef" -}}
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
Validate the volume credentials.

A StorageClass whose Secret is missing a field fails at the first PVC, with an
error from deep inside the CSI sidecars. Failing at render time keeps the cause
next to the configuration.
*/}}
{{- define "juicefs.validate" -}}
{{- if not .Values.volume.metaurl -}}
{{- fail "volume.metaurl must be set: point it at the juicefs-metadb Service, for example postgres://juicefs:<password>@juicefs-metadb.kubesphere-system.svc:5432/juicefs_meta" -}}
{{- end -}}
{{- if not .Values.volume.bucket -}}
{{- fail "volume.bucket must be set: the object store bucket the data blocks are written to, for example http://ks-minio.kubesphere-system.svc:9000/jfs" -}}
{{- end -}}
{{- if not .Values.volume.accessKey -}}
{{- fail "volume.accessKey must be set: the object store access key" -}}
{{- end -}}
{{- if not .Values.volume.secretKey -}}
{{- fail "volume.secretKey must be set: the object store secret key" -}}
{{- end -}}
{{- if not (contains "shared" .Values.storageClass.name) -}}
{{- fail (printf "storageClass.name %q must contain \"shared\": csghub-server picks ReadWriteMany for classes whose name matches 'shared' and ReadWriteOnce for those matching 'local'." .Values.storageClass.name) -}}
{{- end -}}
{{- end -}}

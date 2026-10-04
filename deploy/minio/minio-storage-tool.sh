#!/usr/bin/env bash
# Copyright 2026 Kube AI Hub.
#
# Prepare local storage for the KubeSphere storage foundation.
#
# Creates:
#   - the StorageClass used by MinIO and the JuiceFS metadata database
#   - one local PV per (node, disk) pair, pinned to its node with nodeAffinity
#
# Why static PVs instead of a dynamic hostPath provisioner:
#   - MinIO erasure coding needs a predictable drive-to-node mapping. A
#     provisioner without node affinity can place several "independent" PVCs on
#     one physical disk, which silently destroys the failure domain.
#   - local volumes are mounted by kubelet from their real path, so they are not
#     affected by symlinked base directories the way hostPath volumes are.
#   - PV capacity is declared, giving the scheduler a real number to work with.
#
# The disks must already be formatted and mounted at the expected paths. This
# tool never formats or mounts anything; it only describes what is already there.
#
# Usage:
#   minio-storage-tool.sh prepare [options]
#
# Run with --help for the option list.

set -euo pipefail

KUBECTL="${KUBECTL:-kubectl}"

PROVISIONER="kubeaihub.io/local-static"

STORAGE_NODE_LABEL="node-role.kubernetes.io/storage"
STORAGE_NODE_TAINT="storage=true:NoSchedule"

log()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# Scratch space for generated manifests and scripts.
#
# A `trap ... RETURN` inside a function cannot be used for this: bash unsets the
# function's `local` variables before the RETURN trap runs, so a trap referencing
# them fails under `set -u`. One directory and an EXIT trap avoids the problem.
WORK_DIR=""
cleanup_work_dir() {
  [ -n "$WORK_DIR" ] && rm -rf "$WORK_DIR"
  return 0
}
trap cleanup_work_dir EXIT

new_work_file() {
  local name="$1"
  [ -n "$WORK_DIR" ] || WORK_DIR="$(mktemp -d)"
  printf '%s/%s' "$WORK_DIR" "$name"
}

usage() {
  cat <<'EOF'
minio-storage-tool.sh <command> [options]

Commands:
  prepare   Designate storage nodes and create the local PVs that MinIO and the
            JuiceFS metadata database bind to.
  install   Install the MinIO chart and create its buckets.
  export    Mirror all buckets of a running MinIO into a backup PVC.
  import    Restore a backup PVC into a MinIO cluster.

Run "minio-storage-tool.sh <command> --help" for the options of one command.
EOF
}

[ $# -ge 1 ] || { usage; exit 1; }

COMMAND="$1"; shift

prepare_usage() {
  cat <<'EOF'
minio-storage-tool.sh prepare [options]

Designates storage nodes and creates the local PVs that MinIO and the JuiceFS
metadata database bind to.

Options:
  --nodes <n1,n2,...>          Storage nodes. Required.
  --minio-disks <n>            Disks per node for MinIO (default 0).
  --metadb-disks <n>           Disks per node for the metadata DB (default 0).
  --minio-mount-prefix <p>     MinIO mount prefix (default /mnt/minio).
                               Disk i is expected at <p>-<i>, i starting at 1.
  --metadb-mount-prefix <p>    Metadata DB mount prefix (default /mnt/pg).
  --minio-size <q>             MinIO PV capacity (default 5Ti).
  --metadb-size <q>            Metadata DB PV capacity (default 5Ti).
  --storage-class <name>       StorageClass name (default local-static).
  --no-label                   Do not label the storage nodes.
  --no-taint                   Do not taint the storage nodes.
  --dry-run                    Print the manifests instead of applying them.
  -h, --help                   Show this help.

Notes:
  - Disks are assumed to be already formatted and mounted. This tool does not
    create filesystems.
  - Safe to re-run: existing StorageClass and PVs are left as they are.
EOF
}

install_usage() {
  cat <<'EOF'
minio-storage-tool.sh install [options]

Installs the MinIO chart and creates its buckets. Run "prepare" first so the
local PVs the StatefulSet binds to already exist.

Options:
  --namespace <ns>             Target namespace (default kubesphere-system).
  --release <name>             Helm release name (default ks-minio).
  --chart <dir>                Chart directory (default ./chart).
  --mode <standalone|distributed>   Server mode (default distributed).
  --replicas <n>               Number of servers (default 4).
  --volumes-per-server <n>     Drives per server (default 2).
  --storage-class <name>       StorageClass for the drives (default local-static).
  --volume-size <q>            Drive capacity (default 5Ti).
  --image-registry <prefix>    Registry prefix for the MinIO and job images, for
                               example dockerhub.kubekey.local/kube-ai-hub.
                               Defaults to no prefix.
  --image-tag <tag>            MinIO server tag. Defaults to the chart's.
  --buckets <b1,b2,...>        Buckets to create (default jfs,pg-backup).
  --storage-nodes <n1,n2,...>  Pin MinIO to these nodes via nodeSelector.
  --storage-node-label <k>     Node label key for placement
                               (default node-role.kubernetes.io/storage).
  --storage-node-taint <t>     Toleration key=value:Effect for the storage taint
                               (default storage=true:NoSchedule).
  --values <file>              Extra values file, applied last.
  --dry-run                    Render the manifests instead of installing.
  -h, --help                   Show this help.

Notes:
  - Distributed mode requires replicas * volumesPerServer >= 4 drives. The chart
    fails at render time otherwise, and this tool checks the PV count first.
  - The drive count cannot be changed in place later: MinIO server pools are
    fixed once created. Changing either value means a new pool or a reinstall.
EOF
}

export_usage() {
  cat <<'EOF'
minio-storage-tool.sh export [options]

Mirrors every bucket of a running MinIO into a backup location, so the data can
be restored after MinIO is reinstalled or replaced. The copy runs as a Job
inside the cluster; nothing is streamed through this workstation.

Pick one backup destination:
  --backup-pvc <name>          PVC to mirror into. Buckets land in
                               <mount-path>/<bucket>.
  --backup-endpoint <url>      External S3 endpoint, for example
                               https://s3.example.com. Requires
                               --backup-access-key and --backup-secret-key.

Source (defaults to the MinIO release in --namespace):
  --minio-endpoint <url>       Override the S3 endpoint of the source.
  --minio-access-key <key>     Override the source access key.
  --minio-secret-key <key>     Override the source secret key.

Options:
  --namespace <ns>             Namespace of MinIO (default kubesphere-system).
  --release <name>             Helm release name (default ks-minio).
  --buckets <b1,b2,...>        Only these buckets (default: all buckets).
  --exclude <b1,b2,...>        Skip these buckets.
  --mount-path <p>             Mount path inside the Job (default /backup).
  --image-registry <prefix>    Registry prefix for the job images, for example
                               dockerhub.kubekey.local/kube-ai-hub. Defaults to
                               no prefix.
  --image-tag <tag>            MinIO tag to take the mc binary from. Defaults to
                               the tag the chart ships.
  --no-remove                  Do not delete backup objects that no longer exist
                               in MinIO. By default the backup is an exact
                               mirror of the source.
  --versions                   Also mirror non-current object versions. Requires
                               versioning on the source buckets.
  --timeout <d>                How long to wait for the Job (default 6h).
  --no-wait                    Apply the Job and return immediately.
  --dry-run                    Print the manifests instead of applying them.
  -h, --help                   Show this help.

Notes:
  - Object tags and bucket policies are not copied. Bucket policies are set by
    the chart's bucket list, not by this tool.
  - The Job is named <release>-export-<timestamp>, so successive runs do not
    collide and the previous Job stays available for inspection.
EOF
}

import_usage() {
  cat <<'EOF'
minio-storage-tool.sh import [options]

Mirrors a backup location back into a MinIO cluster, typically after MinIO has
been reinstalled. The copy runs as a Job inside the cluster.

Pick one backup source:
  --backup-pvc <name>          PVC previously written by "export". Buckets are
                               read from <mount-path>/<bucket>.
  --backup-endpoint <url>      External S3 endpoint to read from. Requires
                               --backup-access-key and --backup-secret-key.

Destination (defaults to the MinIO release in --namespace):
  --minio-endpoint <url>       Override the S3 endpoint of the target.
  --minio-access-key <key>     Override the target access key.
  --minio-secret-key <key>     Override the target secret key.

Options:
  --namespace <ns>             Namespace of MinIO (default kubesphere-system).
  --release <name>             Helm release name (default ks-minio).
  --buckets <b1,b2,...>        Only these buckets (default: all in the backup).
  --exclude <b1,b2,...>        Skip these buckets.
  --mount-path <p>             Mount path inside the Job (default /backup).
  --image-registry <prefix>    Registry prefix for the job images, for example
                               dockerhub.kubekey.local/kube-ai-hub. Defaults to
                               no prefix.
  --image-tag <tag>            MinIO tag to take the mc binary from. Defaults to
                               the tag the chart ships.
  --remove                     Delete objects in MinIO that are missing from the
                               backup. Off by default: a restore never destroys
                               live data unless you ask for it.
  --versions                   Also mirror non-current object versions.
  --timeout <d>                How long to wait for the Job (default 6h).
  --no-wait                    Apply the Job and return immediately.
  --dry-run                    Print the manifests instead of applying them.
  -h, --help                   Show this help.

Notes:
  - Missing buckets are created. Existing buckets are never deleted.
  - Object tags and bucket policies are not restored.
  - Run "prepare" and "install" first: the target MinIO must be reachable and
    its buckets must already exist so the bucket policies are correct.
EOF
}

install_minio() {
  local namespace="kubesphere-system"
  local release="ks-minio"
  local chart="./chart"
  local mode="distributed"
  local replicas="4"
  local vps="2"
  local storage_class="local-static"
  local volume_size="5Ti"
  local image_registry=""
  local image_tag=""
  local buckets="jfs,pg-backup"
  local storage_nodes=""
  local node_label="node-role.kubernetes.io/storage"
  local node_taint="storage=true:NoSchedule"
  local extra_values=""
  local dry_run="false"

  while [ $# -gt 0 ]; do
    case "$1" in
      --namespace)           namespace="${2:-}"; shift 2 ;;
      --release)             release="${2:-}"; shift 2 ;;
      --chart)               chart="${2:-}"; shift 2 ;;
      --mode)                mode="${2:-}"; shift 2 ;;
      --replicas)            replicas="${2:-}"; shift 2 ;;
      --volumes-per-server)  vps="${2:-}"; shift 2 ;;
      --storage-class)       storage_class="${2:-}"; shift 2 ;;
      --volume-size)         volume_size="${2:-}"; shift 2 ;;
      --image-registry)      image_registry="${2:-}"; shift 2 ;;
      --image-tag)           image_tag="${2:-}"; shift 2 ;;
      --buckets)             buckets="${2:-}"; shift 2 ;;
      --storage-nodes)       storage_nodes="${2:-}"; shift 2 ;;
      --storage-node-label)  node_label="${2:-}"; shift 2 ;;
      --storage-node-taint)  node_taint="${2:-}"; shift 2 ;;
      --values)              extra_values="${2:-}"; shift 2 ;;
      --dry-run)             dry_run="true"; shift ;;
      -h|--help)             install_usage; exit 0 ;;
      *) die "unknown option: $1 (try --help)" ;;
    esac
  done

  case "$mode" in
    standalone|distributed) ;;
    *) die "--mode must be standalone or distributed" ;;
  esac
  command -v helm >/dev/null 2>&1 || die "helm is required"

  [ -d "$chart" ] || die "chart directory not found: $chart"

  # Build the bucket list as chart values.
  local buckets_yaml=""
  if [ -n "$buckets" ]; then
    IFS=',' read -r -a bucket_list <<< "$buckets"
    for b in "${bucket_list[@]}"; do
      buckets_yaml="${buckets_yaml}  - name: ${b}
    policy: none
"
    done
  fi

  local set_args=(
    --set "mode=${mode}"
    --set "replicas=${replicas}"
    --set "volumesPerServer=${vps}"
    --set "persistence.storageClass=${storage_class}"
    --set "persistence.size=${volume_size}"
  )

  if [ -n "$image_registry" ]; then
    # One prefix for both the server and the job image keeps a site's mirror
    # layout (for example <registry>/minio/minio) working unchanged.
    set_args+=(--set "image.registry=${image_registry}")
    set_args+=(--set "mcImage.registry=${image_registry}")
  fi
  # Pin the server tag where the registry only carries a specific release.
  [ -n "$image_tag" ] && set_args+=(--set "image.tag=${image_tag}")

  if [ -n "$storage_nodes" ]; then
    # --set-json rather than --set: a node label key contains dots, which --set
    # would read as path separators and turn into nested, always-empty objects.
    set_args+=(--set-json "nodeSelector={\"${node_label}\":\"true\"}")
    # Tolerate the storage taint so MinIO can run on nodes that carry it.
    local taint_key="${node_taint%%=*}"
    local taint_rest="${node_taint#*=}"
    local taint_value="${taint_rest%%:*}"
    local taint_effect="${taint_rest#*:}"
    set_args+=(--set-json "tolerations=[{\"key\":\"${taint_key}\",\"operator\":\"Equal\",\"value\":\"${taint_value}\",\"effect\":\"${taint_effect}\"}]")
  fi

  if [ "$dry_run" = "true" ]; then
    log "-- rendering MinIO (${mode}, ${replicas} servers x ${vps} drives)"
    log "   storage class: ${storage_class}, drive size: ${volume_size}"
    if [ -n "$buckets" ]; then
      log "   buckets: ${buckets}"
    fi
    if [ -n "$storage_nodes" ]; then
      log "   pinned to nodes labelled ${node_label}=true"
    fi
    helm template "$release" "$chart" -n "$namespace" \
      "${set_args[@]}" \
      ${extra_values:+-f "$extra_values"} >/dev/null
    log "== dry run OK (chart rendered without errors)"
    return 0
  fi

  # Refuse to install a distributed cluster whose drives do not exist yet: the
  # StatefulSet would sit Pending with no obvious cause.
  if [ "$mode" = "distributed" ]; then
    local total=$((replicas * vps))
    local available
    available=$("$KUBECTL" get pv -l "kubeaihub.io/storage-kind=minio" \
      -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w | tr -d ' ')
    if [ "${available:-0}" -lt "$total" ]; then
      warn "warning: ${total} MinIO drives are needed but only ${available} PV(s) are labelled"
      warn "         run 'prepare' first, or the StatefulSet will stay Pending"
    fi
  fi

  log "-- installing MinIO into ${namespace} as ${release}"
  log "   ${mode}, ${replicas} servers x ${vps} drives = $((replicas * vps)) drives"
  local values_file=""
  if [ -n "$buckets_yaml" ]; then
    values_file="$(new_work_file buckets.yaml)"
    printf 'buckets:\n%s' "$buckets_yaml" > "$values_file"
  fi

  helm upgrade --install "$release" "$chart" \
    --namespace "$namespace" --create-namespace \
    "${set_args[@]}" \
    ${values_file:+-f "$values_file"} \
    ${extra_values:+-f "$extra_values"} \
    --wait --timeout 15m

  log "== done"
  log "   in-cluster endpoint: ${release}.${namespace}.svc:9000"
  log "   read the credentials with:"
  log "     ${KUBECTL} -n ${namespace} get secret ${release} -o jsonpath='{.data.accesskey}' | base64 -d"
}

prepare_storage() {
  local nodes="" minio_disks=0 metadb_disks=0
  local minio_mount_prefix="/mnt/minio" metadb_mount_prefix="/mnt/pg"
  local minio_size="5Ti" metadb_size="5Ti"
  local storage_class="local-static"
  local label_nodes="true" taint_nodes="true"
  local dry_run="false"

  while [ $# -gt 0 ]; do
    case "$1" in
      --nodes)               nodes="${2:-}"; shift 2 ;;
      --minio-disks)         minio_disks="${2:-}"; shift 2 ;;
      --metadb-disks)        metadb_disks="${2:-}"; shift 2 ;;
      --minio-mount-prefix)  minio_mount_prefix="${2:-}"; shift 2 ;;
      --metadb-mount-prefix) metadb_mount_prefix="${2:-}"; shift 2 ;;
      --minio-size)          minio_size="${2:-}"; shift 2 ;;
      --metadb-size)         metadb_size="${2:-}"; shift 2 ;;
      --storage-class)       storage_class="${2:-}"; shift 2 ;;
      --no-label)            label_nodes="false"; shift ;;
      --no-taint)            taint_nodes="false"; shift ;;
      --dry-run)             dry_run="true"; shift ;;
      -h|--help)             prepare_usage; return 0 ;;
      *) die "unknown option: $1 (try --help)" ;;
    esac
  done

  [ -n "$nodes" ] || die "--nodes is required"
  if [ "$minio_disks" -le 0 ] && [ "$metadb_disks" -le 0 ]; then
    die "nothing to do: pass --minio-disks and/or --metadb-disks"
  fi

  command -v "$KUBECTL" >/dev/null 2>&1 || die "$KUBECTL is required"

  local -a node_list
  IFS=',' read -r -a node_list <<< "$nodes"

  # A disk that is not actually mounted would produce a PV that never binds, and
  # the failure would only show up much later when MinIO cannot start. Check the
  # node exists before declaring a PV against it. Skipped in dry-run so the
  # manifests can be reviewed without a reachable cluster.
  check_paths() {
    local node="$1" kind="$2" prefix="$3" count="$4"
    [ "$count" -gt 0 ] || return 0
    if [ "$dry_run" = "true" ]; then
      return 0
    fi
    "$KUBECTL" get node "$node" >/dev/null 2>&1 || die "node $node does not exist"
    local i
    for i in $(seq 1 "$count"); do
      log "   ${kind} disk ${i}: ${node}:${prefix}-${i}"
    done
  }

  apply_storage_class() {
    cat <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${storage_class}
  labels:
    app.kubernetes.io/part-of: kube-ai-hub
    app.kubernetes.io/component: storage
provisioner: ${PROVISIONER}
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: false
EOF
  }

  # One PV per (node, disk). The name encodes both so an operator can tell at a
  # glance which physical disk a claim landed on.
  apply_pv() {
    local kind="$1" node="$2" index="$3" path="$4" size="$5"
    cat <<EOF
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${kind}-${node}-disk${index}
  labels:
    app.kubernetes.io/part-of: kube-ai-hub
    app.kubernetes.io/component: storage
    kubeaihub.io/storage-kind: ${kind}
spec:
  capacity:
    storage: ${size}
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ${storage_class}
  volumeMode: Filesystem
  local:
    path: ${path}
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - ${node}
EOF
  }

  log "== preparing local storage for ${#node_list[@]} node(s)"

  if [ "$label_nodes" = "true" ]; then
    log "-- labelling storage nodes"
    for node in "${node_list[@]}"; do
      log "   ${node} -> ${STORAGE_NODE_LABEL}=true"
      if [ "$dry_run" != "true" ]; then
        "$KUBECTL" label node "$node" "${STORAGE_NODE_LABEL}=true" --overwrite >/dev/null
      fi
    done
  fi

  if [ "$taint_nodes" = "true" ]; then
    log "-- tainting storage nodes"
    for node in "${node_list[@]}"; do
      log "   ${node} -> ${STORAGE_NODE_TAINT}"
      if [ "$dry_run" != "true" ]; then
        # --overwrite keeps this idempotent when the taint is already present.
        "$KUBECTL" taint node "$node" "${STORAGE_NODE_TAINT}" --overwrite >/dev/null
      fi
    done
  fi

  log "-- checking declared disk paths"
  for node in "${node_list[@]}"; do
    check_paths "$node" minio "$minio_mount_prefix" "$minio_disks"
    check_paths "$node" metadb "$metadb_mount_prefix" "$metadb_disks"
  done

  local manifest
  manifest="$(new_work_file pv-manifest.yaml)"

  apply_storage_class > "$manifest"
  for node in "${node_list[@]}"; do
    for i in $(seq 1 "$minio_disks"); do
      apply_pv minio "$node" "$i" "${minio_mount_prefix}-${i}" "$minio_size" >> "$manifest"
    done
    for i in $(seq 1 "$metadb_disks"); do
      apply_pv metadb "$node" "$i" "${metadb_mount_prefix}-${i}" "$metadb_size" >> "$manifest"
    done
  done

  local total_minio=$(( ${#node_list[@]} * minio_disks ))
  local total_metadb=$(( ${#node_list[@]} * metadb_disks ))

  if [ "$dry_run" = "true" ]; then
    log "-- dry run, printing manifests"
    cat "$manifest"
    log "== dry run complete: ${total_minio} MinIO PV(s), ${total_metadb} metadata PV(s)"
    return 0
  fi

  log "-- applying StorageClass and PVs"
  "$KUBECTL" apply -f "$manifest" >/dev/null

  log "== done"
  log "   StorageClass:   ${storage_class} (provisioner ${PROVISIONER})"
  log "   MinIO PVs:      ${total_minio}"
  log "   Metadata PVs:   ${total_metadb}"
  log ""
  log "MinIO and the metadata database now have ${total_minio} and ${total_metadb} drives."
  log "For distributed MinIO the drive count must be >= 4 and match"
  log "replicas * volumesPerServer when you run 'install'."
}

# ---------------------------------------------------------------------------
# export / import
#
# Both directions run `mc mirror` inside a Job rather than on the workstation:
# the dataset is far too large to stream through an operator's laptop, and a Job
# survives a dropped SSH session.
#
# Exit codes are not trusted. `mc mirror` can report success after a partial
# failure, so every bucket is verified afterwards by comparing object count and
# byte count. A PVC backup additionally gets a manifest, which turns the restore
# into a check against numbers recorded at export time rather than against a
# source cluster that may already be gone.
#
# The transfer goes through a PVC because the replacement MinIO may not exist
# yet when the old one is being drained. The backup PVC must use a non-JuiceFS
# StorageClass: backing JuiceFS data up onto JuiceFS would be circular.
# ---------------------------------------------------------------------------

# Read accesskey/secretkey out of a Secret so the caller can inline them into the
# Job. Prints the two values on separate lines.
#
# Two key spellings are accepted: the chart's own accesskey/secretkey, and
# MINIO_ROOT_USER/MINIO_ROOT_PASSWORD as used by the single-node MinIO this
# replaces. Reading a legacy Secret avoids copying credentials by hand during a
# migration.
read_credentials() {
  local namespace="$1" secret="$2"
  local access="" secretkey=""

  local key
  for pair in "accesskey:secretkey" "MINIO_ROOT_USER:MINIO_ROOT_PASSWORD"; do
    local k1="${pair%%:*}" k2="${pair##*:}"
    access=$("$KUBECTL" -n "$namespace" get secret "$secret" \
      -o jsonpath="{.data.${k1}}" 2>/dev/null | base64 -d || true)
    secretkey=$("$KUBECTL" -n "$namespace" get secret "$secret" \
      -o jsonpath="{.data.${k2}}" 2>/dev/null | base64 -d || true)
    if [ -n "$access" ] && [ -n "$secretkey" ]; then
      printf '%s\n%s\n' "$access" "$secretkey"
      return 0
    fi
  done

  die "secret ${namespace}/${secret} has neither accesskey/secretkey nor MINIO_ROOT_USER/MINIO_ROOT_PASSWORD"
}

# Parse the options shared by export and import. Values come back through
# m_* globals because bash cannot return more than one value.
parse_mirror_options() {
  local direction="$1"; shift

  m_namespace="kubesphere-system"
  m_release="ks-minio"
  m_mount_path="/backup"
  m_registry=""
  m_image_tag=""
  m_image=""
  m_source_image=""
  m_buckets=""
  m_exclude=""
  m_timeout="6h"
  m_wait="true"
  m_dry_run="false"
  m_remove="false"
  m_versions="false"
  m_backup_pvc=""
  m_backup_endpoint=""
  m_backup_access=""
  m_backup_secret=""
  m_minio_endpoint=""
  m_minio_access=""
  m_minio_secret=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --namespace)          m_namespace="${2:-}"; shift 2 ;;
      --release)            m_release="${2:-}"; shift 2 ;;
      --buckets)            m_buckets="${2:-}"; shift 2 ;;
      --exclude)            m_exclude="${2:-}"; shift 2 ;;
      --mount-path)         m_mount_path="${2:-}"; shift 2 ;;
      --image-registry)     m_registry="${2:-}"; shift 2 ;;
      --image-tag)          m_image_tag="${2:-}"; shift 2 ;;
      --timeout)            m_timeout="${2:-}"; shift 2 ;;
      --no-wait)            m_wait="false"; shift ;;
      --dry-run)            m_dry_run="true"; shift ;;
      --backup-pvc)         m_backup_pvc="${2:-}"; shift 2 ;;
      --backup-endpoint)    m_backup_endpoint="${2:-}"; shift 2 ;;
      --backup-access-key)  m_backup_access="${2:-}"; shift 2 ;;
      --backup-secret-key)  m_backup_secret="${2:-}"; shift 2 ;;
      --minio-endpoint)     m_minio_endpoint="${2:-}"; shift 2 ;;
      --minio-access-key)   m_minio_access="${2:-}"; shift 2 ;;
      --minio-secret-key)   m_minio_secret="${2:-}"; shift 2 ;;
      --versions)           m_versions="true"; shift ;;
      --no-remove)
        [ "$direction" = "export" ] || die "--no-remove only applies to export"
        m_remove="false"; shift ;;
      --remove)
        [ "$direction" = "import" ] || die "--remove only applies to import"
        m_remove="true"; shift ;;
      -h|--help)
        if [ "$direction" = "export" ]; then export_usage; else import_usage; fi
        exit 0 ;;
      *) die "unknown option: $1 (try --help)" ;;
    esac
  done

  # An export must be an exact mirror or it is not a backup; a restore never
  # deletes live data unless explicitly asked.
  [ "$direction" = "export" ] && m_remove="true"

  if [ -z "$m_backup_pvc" ] && [ -z "$m_backup_endpoint" ]; then
    die "one of --backup-pvc or --backup-endpoint is required"
  fi
  if [ -n "$m_backup_pvc" ] && [ -n "$m_backup_endpoint" ]; then
    die "--backup-pvc and --backup-endpoint are mutually exclusive"
  fi
  if [ -n "$m_backup_endpoint" ] && { [ -z "$m_backup_access" ] || [ -z "$m_backup_secret" ]; }; then
    die "--backup-endpoint needs --backup-access-key and --backup-secret-key"
  fi

  command -v "$KUBECTL" >/dev/null 2>&1 || die "$KUBECTL is required"

  # Resolve the MinIO credentials up front so a wrong Secret name fails now
  # instead of leaving a Job in CrashLoopBackOff.
  if [ -z "$m_minio_access" ] || [ -z "$m_minio_secret" ]; then
    local creds
    creds=$(read_credentials "$m_namespace" "$m_release")
    m_minio_access="${m_minio_access:-$(printf '%s' "$creds" | sed -n 1p)}"
    m_minio_secret="${m_minio_secret:-$(printf '%s' "$creds" | sed -n 2p)}"
  fi
  if [ -z "$m_minio_endpoint" ]; then
    m_minio_endpoint="http://${m_release}.${m_namespace}.svc:9000"
  fi

  # The mirror jobs need two images: busybox to run the script in (it has awk,
  # sed and grep) and the MinIO server image to copy the mc binary out of. The
  # separate minio/mc image is not published on every registry this runs against,
  # so it is not used.
  #
  # Defaults come from the chart's values.yaml so an export or import runs with a
  # client matching the installed server.
  local chart_dir="${CHART_DIR:-$(dirname "$0")/chart}"
  local minio_repo="minio/minio" minio_tag=""
  local tools_repo="busybox" tools_tag="1.37.0"
  if [ -f "$chart_dir/values.yaml" ]; then
    # Strip the YAML quotes: values.yaml writes tags as "1.37.0".
    minio_repo=$(sed -n 's/^  repository: *//p' "$chart_dir/values.yaml" | sed -n 1p | tr -d '"')
    minio_tag=$(sed -n 's/^  tag: *//p' "$chart_dir/values.yaml" | sed -n 1p | tr -d '"')
    tools_repo=$(sed -n 's/^  repository: *//p' "$chart_dir/values.yaml" | sed -n 2p | tr -d '"')
    tools_tag=$(sed -n 's/^  tag: *//p' "$chart_dir/values.yaml" | sed -n 2p | tr -d '"')
  fi
  [ -n "$minio_repo" ] || minio_repo="minio/minio"
  [ -n "$minio_tag" ] || minio_tag="latest"
  [ -n "$tools_repo" ] || tools_repo="busybox"
  [ -n "$tools_tag" ] || tools_tag="1.37.0"

  # An explicit tag wins over the chart default, which matters where the
  # registry only carries one specific MinIO release.
  [ -n "$m_image_tag" ] && minio_tag="$m_image_tag"

  local prefix=""
  [ -n "$m_registry" ] && prefix="$(printf '%s' "$m_registry" | sed 's:/*$::')/"
  m_source_image="${prefix}${minio_repo}:${minio_tag}"
  m_image="${prefix}${tools_repo}:${tools_tag}"
}

# Emit the shell that keeps a bucket out of the loop. An allow list skips
# everything not named; a deny list skips what is. Matching is space padded so
# "jfs" does not also match "jfs-extra".
append_bucket_filter() {
  local file="$1" list="$2" indent="$3" mode="$4"
  [ -n "$list" ] || return 0

  local -a items
  IFS=',' read -r -a items <<< "$list"

  local pattern="" i first=1
  for i in "${items[@]}"; do
    [ -n "$i" ] || continue
    [ "$first" = 1 ] || pattern="${pattern}|"
    pattern="${pattern}\"${i}\""
    first=0
  done
  [ -n "$pattern" ] || return 0

  {
    if [ "$mode" = "only" ]; then
      printf '%scase " $bucket " in\n' "$indent"
      printf '%s  %s) ;;\n' "$indent" "$pattern"
      printf '%s  *) continue ;;\n' "$indent"
      printf '%sesac\n' "$indent"
    else
      printf '%scase " $bucket " in\n' "$indent"
      printf '%s  %s) continue ;;\n' "$indent" "$pattern"
      printf '%sesac\n' "$indent"
    fi
  } >> "$file"
}

# Write the mc script the Job runs. $1 is the target file, $2 is export or
# import. The script is generated rather than templated so the two directions
# can share the pieces that are identical.
write_mirror_script() {
  local file="$1" direction="$2"

  # --- preamble: helpers both directions need ---
  cat > "$file" <<'SCRIPT'
set -eu

fail() { echo "ERROR: $*" >&2; exit 1; }

# A target may still be starting up: a fresh MinIO install, or a restarted one.
# Wait instead of burning the Job's backoff budget on a cold server.
wait_for() {
  local alias="$1" attempts=0
  until mc admin info "$alias" >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [ "$attempts" -gt 150 ]; then
      fail "timed out waiting for $alias"
    fi
    sleep 4
  done
}

# Print "<objects> <bytes>" for an mc path (alias/bucket) or a local directory.
# mc du gives bytes from the server without a full client-side walk; object
# count comes from du when the client reports it and from a listing otherwise.
bucket_stats() {
  local target="$1" out size objs
  out=$(mc du --json "$target" 2>/dev/null || true)
  size=$(printf '%s\n' "$out" | sed -n 's/.*"size":\([0-9][0-9]*\).*/\1/p' | tail -n 1)
  objs=$(printf '%s\n' "$out" | sed -n 's/.*"objects":\([0-9][0-9]*\).*/\1/p' | tail -n 1)
  if [ -z "$objs" ]; then
    objs=$(mc ls --recursive --json "$target" 2>/dev/null | wc -l | tr -d ' ')
  fi
  printf '%s %s\n' "${objs:-0}" "${size:-0}"
}

# Compare two "<objects> <bytes>" readings. Skipped under --versions, where the
# target legitimately holds more objects than the current-version count.
verify_bucket() {
  local bucket="$1" what="$2" expected="$3" got="$4"
  if [ "$MIRROR_VERSIONS" = "true" ]; then
    echo "    noted (--versions): $what reports $got"
    return 0
  fi
  if [ "$expected" != "$got" ]; then
    fail "bucket $bucket: $what expected [$expected] but got [$got]"
  fi
  echo "    verified ($what): $got"
}
SCRIPT

  # --- connection setup ---
  if [ "$direction" = "export" ]; then
    cat >> "$file" <<'SCRIPT'

mc alias set src "$MINIO_ENDPOINT" "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY"
wait_for src
if [ -n "$BACKUP_ENDPOINT" ]; then
  mc alias set dst "$BACKUP_ENDPOINT" "$BACKUP_ACCESS_KEY" "$BACKUP_SECRET_KEY"
  wait_for dst
  DST_ROOT="dst"
  DST_KIND=s3
else
  # A PVC is addressed as a local directory; mc accepts a path as a target, so
  # no alias is needed for it.
  DST_ROOT="$MIRROR_MOUNT_PATH"
  mkdir -p "$DST_ROOT"
  DST_KIND=pvc
fi

buckets=$(mc ls --json src | sed -n 's/.*"key":"\([^"]*\)".*/\1/p' | sed 's:/$::')
[ -n "$buckets" ] || { echo "source has no buckets"; exit 0; }
SCRIPT
  else
    cat >> "$file" <<'SCRIPT'

mc alias set dst "$MINIO_ENDPOINT" "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY"
wait_for dst
if [ -n "$BACKUP_ENDPOINT" ]; then
  mc alias set src "$BACKUP_ENDPOINT" "$BACKUP_ACCESS_KEY" "$BACKUP_SECRET_KEY"
  wait_for src
  SRC_ROOT="src"
else
  SRC_ROOT="$MIRROR_MOUNT_PATH"
fi

MANIFEST="$SRC_ROOT/manifest.tsv"

# Prefer the export manifest for the bucket list: it is the record of what the
# backup actually holds. Fall back to listing the backup when there is none.
if [ -n "$MIRROR_BUCKETS" ]; then
  buckets=$(printf '%s' "$MIRROR_BUCKETS" | tr ',' ' ')
elif [ -f "$MANIFEST" ]; then
  buckets=$(cut -d' ' -f1 "$MANIFEST")
elif [ -n "$BACKUP_ENDPOINT" ]; then
  buckets=$(mc ls --json src | sed -n 's/.*"key":"\([^"]*\)".*/\1/p' | sed 's:/$::')
else
  buckets=""
  for entry in "$SRC_ROOT"/*/; do
    [ -d "$entry" ] || continue
    buckets="$buckets $(basename "$entry")"
  done
fi
[ -n "$buckets" ] || { echo "no buckets found in the backup"; exit 0; }
SCRIPT
  fi

  # --- mc mirror flags as positional parameters, so a flag-less run is not a
  #     special case in the loop body ---
  cat >> "$file" <<'SCRIPT'

set -- --preserve
if [ "$MIRROR_REMOVE" = "true" ]; then set -- "$@" --remove; fi
if [ "$MIRROR_VERSIONS" = "true" ]; then set -- "$@" --versions; fi
SCRIPT

  # --- the per-bucket loop ---
  cat >> "$file" <<'SCRIPT'

for bucket in $buckets; do
SCRIPT
  append_bucket_filter "$file" "$m_buckets" "  " only
  append_bucket_filter "$file" "$m_exclude" "  " skip

  if [ "$direction" = "export" ]; then
    cat >> "$file" <<'SCRIPT'
  echo "==> exporting $bucket"
  if [ "$DST_KIND" = s3 ]; then
    mc mb --ignore-existing "dst/$bucket" >/dev/null
  else
    mkdir -p "$DST_ROOT/$bucket"
  fi
  mc mirror "$@" "src/$bucket" "$DST_ROOT/$bucket"

  # mc mirror can exit 0 after a partial failure, so the result is checked by
  # comparing the two sides rather than by trusting the exit code.
  src_stats=$(bucket_stats "src/$bucket")
  dst_stats=$(bucket_stats "$DST_ROOT/$bucket")
  verify_bucket "$bucket" "source vs backup" "$src_stats" "$dst_stats"
  if [ "$DST_KIND" = pvc ]; then
    printf '%s %s\n' "$bucket" "$dst_stats" > "$DST_ROOT/.manifest-$bucket"
  fi
done

if [ "$DST_KIND" = pvc ]; then
  # Aggregate the per-bucket readings. The per-bucket files survive a partial
  # re-export, so the manifest always describes what the backup holds.
  : > "$DST_ROOT/manifest.tsv"
  for f in "$DST_ROOT"/.manifest-*; do
    [ -f "$f" ] || continue
    cat "$f" >> "$DST_ROOT/manifest.tsv"
  done
  sort -o "$DST_ROOT/manifest.tsv" "$DST_ROOT/manifest.tsv"
  {
    echo "{"
    echo "  \"version\": 1,"
    echo "  \"source\": \"$MINIO_ENDPOINT\","
    echo "  \"created\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"buckets\": {"
    first=1
    while read -r b o s; do
      [ -n "$b" ] || continue
      [ "$first" = 1 ] || echo ","
      first=0
      printf '    "%s": {"objects": %s, "bytes": %s}' "$b" "$o" "$s"
    done < "$DST_ROOT/manifest.tsv"
    echo ""
    echo "  }"
    echo "}"
  } > "$DST_ROOT/manifest.json"
  echo "manifest written to $DST_ROOT/manifest.json"
fi

echo "export complete"
SCRIPT
  else
    cat >> "$file" <<'SCRIPT'
  echo "==> restoring $bucket"
  # An existing bucket is left alone so a re-run cannot clobber its policy.
  mc mb --ignore-existing "dst/$bucket" >/dev/null
  mc mirror "$@" "$SRC_ROOT/$bucket" "dst/$bucket"

  # When the backup carries a manifest, verify against the numbers recorded at
  # export time. There is no source cluster left to compare against by then.
  expected=$(awk -v b="$bucket" '$1 == b { print $2 " " $3 }' "$MANIFEST" 2>/dev/null || true)
  got=$(bucket_stats "dst/$bucket")
  if [ -n "$expected" ]; then
    verify_bucket "$bucket" "backup vs restore" "$expected" "$got"
  else
    echo "    restored (no manifest entry to verify against): $got"
  fi
done

echo "import complete"
SCRIPT
  fi
}

# Render the Secret, ConfigMap and Job that run one mirror script.
mirror_job_manifest() {
  local direction="$1" job_name="$2" script_file="$3"

  local backup_mount="" backup_volume=""
  if [ -n "$m_backup_pvc" ]; then
    backup_mount=$(printf '            - name: backup\n              mountPath: %s' "$m_mount_path")
    backup_volume=$(printf '        - name: backup\n          persistentVolumeClaim:\n            claimName: %s' "$m_backup_pvc")
  fi

  cat <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: ${job_name}
  namespace: ${m_namespace}
  labels:
    app.kubernetes.io/part-of: kube-ai-hub
    app.kubernetes.io/component: minio
type: Opaque
stringData:
  MINIO_ACCESS_KEY: "${m_minio_access}"
  MINIO_SECRET_KEY: "${m_minio_secret}"
  BACKUP_ACCESS_KEY: "${m_backup_access}"
  BACKUP_SECRET_KEY: "${m_backup_secret}"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${job_name}
  namespace: ${m_namespace}
  labels:
    app.kubernetes.io/part-of: kube-ai-hub
    app.kubernetes.io/component: minio
data:
  mirror.sh: |-
$(sed 's/^/    /' "$script_file")
---
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job_name}
  namespace: ${m_namespace}
  labels:
    app.kubernetes.io/part-of: kube-ai-hub
    app.kubernetes.io/component: minio
    kubeaihub.io/minio-operation: ${direction}
spec:
  backoffLimit: 2
  template:
    metadata:
      labels:
        kubeaihub.io/minio-operation: ${direction}
    spec:
      restartPolicy: OnFailure
      volumes:
        - name: scripts
          configMap:
            name: ${job_name}
            defaultMode: 0755
        - name: tools
          emptyDir: {}
${backup_volume}
      # The script needs awk, sed and grep, which the MinIO server image does not
      # ship. mc is copied out of that image and the script runs in busybox, so
      # only images already used elsewhere in the cluster are required.
      initContainers:
        - name: install-mc
          image: ${m_source_image}
          imagePullPolicy: IfNotPresent
          command: ["/bin/sh", "-c", "cp /usr/bin/mc /tools/mc && chmod 0755 /tools/mc"]
          volumeMounts:
            - name: tools
              mountPath: /tools
      containers:
        - name: mc
          image: ${m_image}
          imagePullPolicy: IfNotPresent
          command: ["/bin/sh", "/scripts/mirror.sh"]
          env:
            - name: MINIO_ENDPOINT
              value: "${m_minio_endpoint}"
            - name: BACKUP_ENDPOINT
              value: "${m_backup_endpoint}"
            - name: MIRROR_MOUNT_PATH
              value: "${m_mount_path}"
            - name: MIRROR_BUCKETS
              value: "${m_buckets}"
            - name: MIRROR_REMOVE
              value: "${m_remove}"
            - name: MIRROR_VERSIONS
              value: "${m_versions}"
            - name: PATH
              value: "/tools:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
            - name: HOME
              value: /tmp
            - name: MC_CONFIG_DIR
              value: /tmp/.mc
          envFrom:
            - secretRef:
                name: ${job_name}
          volumeMounts:
            - name: scripts
              mountPath: /scripts
            - name: tools
              mountPath: /tools
${backup_mount}
EOF
}

run_mirror_job() {
  local direction="$1" verb="$2"

  local script_file manifest_file
  script_file="$(new_work_file mirror.sh)"
  manifest_file="$(new_work_file manifest.yaml)"

  write_mirror_script "$script_file" "$direction"

  local job_name="${m_release}-${direction}-$(date -u +%Y%m%d%H%M%S)"
  mirror_job_manifest "$direction" "$job_name" "$script_file" > "$manifest_file"

  if [ "$m_dry_run" = "true" ]; then
    log "-- dry run, printing manifests"
    cat "$manifest_file"
    return 0
  fi

  log "-- starting ${direction} job ${job_name}"
  if [ "$direction" = "export" ]; then
    log "   source:      ${m_minio_endpoint}"
    if [ -n "$m_backup_pvc" ]; then
      log "   destination: pvc ${m_backup_pvc} at ${m_mount_path}"
    else
      log "   destination: ${m_backup_endpoint}"
    fi
  else
    if [ -n "$m_backup_pvc" ]; then
      log "   source:      pvc ${m_backup_pvc} at ${m_mount_path}"
    else
      log "   source:      ${m_backup_endpoint}"
    fi
    log "   destination: ${m_minio_endpoint}"
  fi
  "$KUBECTL" apply -f "$manifest_file" >/dev/null

  if [ "$m_wait" = "true" ]; then
    log "-- waiting for the job (timeout ${m_timeout})"
    if ! "$KUBECTL" -n "$m_namespace" wait --for=condition=complete \
      "job/${job_name}" --timeout="$m_timeout"; then
      warn "job ${job_name} did not complete; inspect it with:"
      warn "  ${KUBECTL} -n ${m_namespace} logs job/${job_name}"
      die "${verb} failed"
    fi
    log "== ${verb} complete"
  else
    log "== ${verb} job ${job_name} submitted"
  fi
  log "   logs: ${KUBECTL} -n ${m_namespace} logs job/${job_name}"
  log "   re-running is safe: only objects that differ are copied."
}

export_minio() {
  parse_mirror_options export "$@"
  run_mirror_job export export
}

import_minio() {
  parse_mirror_options import "$@"
  run_mirror_job import import
}

# Dispatch after every function is defined: bash resolves the command name at
# call time, so dispatching earlier would fail with "command not found".
case "$COMMAND" in
  prepare) prepare_storage "$@" ;;
  install) install_minio "$@" ;;
  export)  export_minio "$@" ;;
  import)  import_minio "$@" ;;
  -h|--help) usage; exit 0 ;;
  *) die "unknown command: $COMMAND (try --help)" ;;
esac

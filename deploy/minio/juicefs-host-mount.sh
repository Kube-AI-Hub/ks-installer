#!/usr/bin/env bash
# Copyright 2026 Kube AI Hub.
#
# Mount the JuiceFS volume on a node's host so operators can look at and edit
# model files directly.
#
# The cluster already reaches the volume through the CSI driver, but that is only
# visible inside pods. When a model needs inspecting, fixing or hand-copying,
# nobody wants to shell into a mount pod. This mounts the same volume at
# <mount-path> on the host with the same block cache directory, so the host reads
# the blocks the cluster has already downloaded.
#
# Run as root on every node that should see the files. The script is idempotent:
# re-running it re-renders the configuration and restarts the unit.
#
# Why the mount runs in a container:
#   - The juicefs client does not run on a bare host. It dlopens the client
#     library of every metadata engine it was built with - FoundationDB, Ceph
#     RADOS, GlusterFS - while starting up, even for a volume that uses none of
#     them, so a copied-out binary exits immediately with a missing library.
#     Installing that whole stack on the host to talk to PostgreSQL would be
#     absurd, so the client runs from the image that already has it, which is
#     exactly how the CSI driver runs its own mounts.
#   - The FUSE mount is made inside that container on a shared bind mount, so the
#     kernel propagates it back to the host and <mount-path> is a real mount for
#     everyone on the node.
#
# Why the host can reach the volume at all:
#   - JuiceFS needs the metadata database and the object store. The container
#     shares the host's network namespace, where the Service ClusterIPs are
#     routable. Those are addressed by IP rather than by name because the node's
#     resolver is systemd-resolved and does not resolve *.svc.cluster.local.
#
# Usage:
#   juicefs-host-mount.sh [options]
#
# Run with --help for the option list.

set -euo pipefail

KUBECTL="${KUBECTL:-kubectl}"
DOCKER="${DOCKER:-docker}"

CONFIG_DIR="/etc/juicefs"
UNIT_NAME="juicefs-kubeaihub"
# The mount container is named after the unit so a leftover from a hard reboot is
# recognisable and can be replaced at the next start.
CONTAINER_NAME="${UNIT_NAME}"
ENV_FILE="${CONFIG_DIR}/${UNIT_NAME}.env"
MOUNT_SCRIPT="/usr/local/bin/${UNIT_NAME}-mount"
UNIT_FILE="/etc/systemd/system/${UNIT_NAME}.service"
FUSE_CONF="/etc/fuse.conf"

# Defaults are the ones the storage foundation installs, so a plain run on a
# standard cluster needs no options at all. The credentials come from the
# StorageClass rather than from a guessed Secret name: the CSI parameters on the
# class name the Secret and its namespace, so a renamed release cannot leave this
# script reading the wrong object.
STORAGE_CLASS="juicefs-shared"
NAMESPACE=""
SECRET_NAME=""
# Which volume to expose. The CSI driver gives every PersistentVolume its own
# directory inside the JuiceFS filesystem, named after the PV, so mounting the
# filesystem root would show UUIDs instead of models. Point this at the claim the
# platform caches models in and the subdirectory is resolved from the bound
# volume, which is how <mount-path>/admin/Qwen3.5-2B becomes the path.
# Use "none" to mount the filesystem root.
PVC="spaces/csghub-model-cache"
MOUNT_PATH="/data1/kube-ai-hub/models"
CACHE_DIR="/data1/juicefs-cache"
IMAGE=""

FREE_SPACE_RATIO="0.1"
CACHE_EVICTION="2-random"
# The CSI mount pod runs the client on the host's network namespace and leaves
# the metrics address at its default, so the default is taken. Give this one a
# distinct address instead of failing to bind.
METRICS_ADDR="127.0.0.1:9568"

DRY_RUN="false"
UNINSTALL="false"
NO_START="false"

log()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
juicefs-host-mount.sh [options]

Mounts the JuiceFS volume on this node under <mount-path> and keeps it mounted
across reboots with a systemd unit.

Options:
  --mount-path <dir>        Where to mount the volume on the host
                            (default /data1/kube-ai-hub/models).
  --cache-dir <dir>         Node local block cache. Point it at the same
                            directory the cluster uses so a file the cluster
                            already read is served from local disk instead of
                            being fetched again (default /data1/juicefs-cache).
  --storage-class <name>    StorageClass whose CSI parameters name the volume
                            Secret (default juicefs-shared).
  --pvc <ns>/<name>         Expose this claim's directory as the mount root, so
                            the mount shows models rather than PersistentVolume
                            names (default spaces/csghub-model-cache, the claim
                            the platform caches models in). Pass "none" to mount
                            the whole filesystem.
  --secret <name>           Volume Secret, if it is not the one the
                            StorageClass points at.
  --namespace <ns>          Namespace of the volume Secret, overriding the one
                            recorded on the StorageClass.
  --image <img>             Image holding the juicefs client. Defaults to
                            $JUICEFS_MOUNT_IMAGE, else the image the CSI driver
                            itself mounts with.
  --free-space-ratio <r>    Stop caching once the filesystem holding the cache
                            is this full (default 0.1).
  --cache-eviction <mode>   Cache eviction policy, none or 2-random
                            (default 2-random).
  --fuse-conf <file>        Where the mount records that non-root users may enter
                            it (default /etc/fuse.conf). Created if missing.
  --no-start                Write the configuration but do not start the unit.
  --uninstall               Stop and remove the unit and its configuration. The
                            data in the volume is not touched, and neither is
                            the cache directory.
  --dry-run                 Print what would be written instead of writing it.
  -h, --help                Show this help.

Notes:
  - Run as root: the mount is visible to the whole node and the unit is a system
    unit.
  - Docker must be installed and running; the unit pulls in docker.service.
  - The node must be able to reach the metadata database and the object store.
    Both are resolved to ClusterIPs, so this only works on a cluster node.
  - Writing through this mount is possible. Prefer editing models while the
    inference instance is stopped: an engine that already loaded its weights is
    unaffected, but the next start reads whatever the files now contain.
EOF
}

require_root() {
  [ "$(id -u)" = "0" ] || die "run as root: the mount is node wide and the unit is a system unit"
}

# ---------------------------------------------------------------------------
# Cluster lookups
# ---------------------------------------------------------------------------

# Read the volume credentials.
#
# The Secret the CSI driver uses is the source of truth: it holds the metadata
# URL, the bucket and the object store keys, so nothing is recomputed here and a
# rotated credential is picked up by re-running the script. Which Secret that is
# comes from the StorageClass, not from a guessed name.
read_volume_secret() {
  command -v "$KUBECTL" >/dev/null 2>&1 || die "$KUBECTL is required"

  if [ -z "$SECRET_NAME" ]; then
    local param_secret param_ns
    param_secret=$("$KUBECTL" get sc "$STORAGE_CLASS" \
      -o jsonpath='{.parameters.csi\.storage\.k8s\.io/node-publish-secret-name}' 2>/dev/null || true)
    param_ns=$("$KUBECTL" get sc "$STORAGE_CLASS" \
      -o jsonpath='{.parameters.csi\.storage\.k8s\.io/node-publish-secret-namespace}' 2>/dev/null || true)
    [ -n "$param_secret" ] || die "StorageClass ${STORAGE_CLASS} does not name a node publish secret; pass --secret"
    SECRET_NAME="$param_secret"
    [ -n "$NAMESPACE" ] || NAMESPACE="$param_ns"
  fi
  [ -n "$NAMESPACE" ] || die "no namespace for secret ${SECRET_NAME}; pass --namespace"

  "$KUBECTL" -n "$NAMESPACE" get secret "$SECRET_NAME" >/dev/null 2>&1 \
    || die "cannot read secret ${NAMESPACE}/${SECRET_NAME}"

  local key value
  for key in metaurl name storage bucket access-key secret-key; do
    value=$("$KUBECTL" -n "$NAMESPACE" get secret "$SECRET_NAME" \
      -o "jsonpath={.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null || true)
    [ -n "$value" ] || die "secret ${NAMESPACE}/${SECRET_NAME} has no ${key}"
    case "$key" in
      metaurl) METAURL="$value" ;;
      name) VOLUME_NAME="$value" ;;
      storage) STORAGE="$value" ;;
      bucket) BUCKET="$value" ;;
      access-key) ACCESS_KEY="$value" ;;
      secret-key) SECRET_KEY="$value" ;;
    esac
  done
}

# Replace the Service name in a URL with its ClusterIP.
#
# The container shares the host's network namespace, so it reaches cluster
# Services by address but cannot resolve their names: the node's resolver is
# systemd-resolved, which knows nothing about cluster DNS. The namespace comes
# from the URL itself when it is a fully qualified "<service>.<namespace>.svc"
# name, so the metadata database and the object store do not have to live in the
# same namespace as the Secret.
resolve_cluster_host() {
  local url="$1"

  # Authority is everything after "scheme://" up to the first "/". Note the
  # metadata URL carries credentials, so the host is not simply the part before
  # the first ":".
  local authority
  authority=$(printf '%s' "$url" | sed -e 's#^[A-Za-z0-9+.-]*://##' -e 's#/.*$##')
  [ -n "$authority" ] || { printf '%s' "$url"; return 0; }

  # Drop "user:password@". The credentials stay in the URL itself; only the host
  # is replaced below.
  local host_port="${authority##*@}"
  local host="${host_port%%:*}"
  local port=""
  if [ "$host_port" != "$host" ]; then
    port=":${host_port##*:}"
  fi

  # Already an address.
  if printf '%s' "$host" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    printf '%s' "$url"
    return 0
  fi

  # "ks-minio.kubesphere-system.svc" -> service "ks-minio" in "kubesphere-system".
  local service="${host%%.*}"
  local rest="${host#*.}"
  local ns="$NAMESPACE"
  case "$rest" in
    *.*) ns="${rest%%.*}" ;;
  esac

  local ip
  ip=$("$KUBECTL" -n "$ns" get svc "$service" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
  if [ -z "$ip" ] || [ "$ip" = "None" ]; then
    warn "cannot resolve Service ${ns}/${service}; leaving ${host} in place"
    printf '%s' "$url"
    return 0
  fi
  printf '%s' "${url/"$host_port"/"${ip}${port}"}"
}

# Resolve the directory inside the JuiceFS filesystem that backs a claim.
#
# The CSI driver lays every PersistentVolume out as its own directory named after
# the PV, so the filesystem root is a list of "pvc-<uuid>" entries. Resolving the
# claim to its bound PV keeps the mount readable without an operator having to
# look up a UUID.
resolve_sub_path() {
  [ "$PVC" = "none" ] && return 0

  local ns="${PVC%%/*}" name="${PVC#*/}"
  [ -n "$ns" ] && [ -n "$name" ] && [ "$ns" != "$PVC" ] \
    || die "--pvc must be <namespace>/<name>, or none"

  local pv
  pv=$("$KUBECTL" -n "$ns" get pvc "$name" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)
  [ -n "$pv" ] || die "cannot find ${ns}/${name}; is it created yet?"

  SUB_PATH=$("$KUBECTL" get pv "$pv" -o jsonpath='{.spec.csi.volumeAttributes.subPath}' 2>/dev/null || true)
  if [ -z "$SUB_PATH" ]; then
    # JuiceFS defaults the subdirectory to the volume handle when the StorageClass
    # does not set one, which is the PV name for this driver.
    SUB_PATH="$pv"
  fi
}

# The image holding the juicefs client.
#
# The CSI driver is already configured with one, so read it from there rather
# than hardcoding a tag that drifts from the deployment. There is no fallback: an
# image that cannot be pulled would fail the mount with a confusing error, so it
# is better to say so here.
discover_image() {
  if [ -n "${JUICEFS_MOUNT_IMAGE:-}" ]; then
    printf '%s' "$JUICEFS_MOUNT_IMAGE"
    return 0
  fi
  local ref
  ref=$("$KUBECTL" get deploy,statefulset,daemonset -A -l app.kubernetes.io/name=juicefs \
    -o jsonpath='{range .items[*]}{range .spec.template.spec.containers[*]}''{range .env[?(@.name=="JUICEFS_MOUNT_IMAGE")]}{.value}{"\n"}{end}''{end}{end}' 2>/dev/null | head -n 1)
  if [ -n "$ref" ]; then
    printf '%s' "$ref"
    return 0
  fi
  die "cannot find the juicefs client image (no CSI workload declares JUICEFS_MOUNT_IMAGE); pass --image"
}

# ---------------------------------------------------------------------------
# Rendered files
# ---------------------------------------------------------------------------

render_mount_script() {
  cat <<EOF
#!/bin/sh
# Copyright 2026 Kube AI Hub.
#
# Written by juicefs-host-mount.sh. Starts the JuiceFS client for the host mount.
# Kept as a script rather than a long ExecStart so the quoting stays readable.
#
# The values the client needs are read from the environment file the unit
# declares, not interpolated here, because Docker only supplies that file to the
# container and not to this script.

set -eu

# --network host is what makes the Service ClusterIPs in the credentials
# reachable: they are implemented in the host's network namespace.
#
# The two bind mounts are rshared on purpose. FUSE mounts are made inside the
# container, and shared propagation is what lifts them back out to the host.
# --privileged is required for that plus access to /dev/fuse.
#
# A container from an unclean shutdown may still hold the name; replacing it is
# cheaper than diagnosing why the unit will not start.
${DOCKER} rm -f ${CONTAINER_NAME} >/dev/null 2>&1 || true

exec ${DOCKER} run --rm --name ${CONTAINER_NAME} \\
  --privileged \\
  --network host \\
  --env-file ${ENV_FILE} \\
  --mount "type=bind,src=${MOUNT_PATH},dst=${MOUNT_PATH},bind-propagation=rshared" \\
  --mount "type=bind,src=${CACHE_DIR},dst=${CACHE_DIR},bind-propagation=rshared" \\
  --mount "type=bind,src=${FUSE_CONF},dst=/etc/fuse.conf,readonly" \\
  --entrypoint /bin/sh \\
  ${IMAGE} -c '
set -eu
# The client reads its credentials from the environment; it has no flags for
# them. Keeping them there also keeps them out of a process list, which on a
# shared node is world readable.
#
# The client stays in the foreground by default, which is what keeps this
# container alive and therefore the mount alive.
set -- \\
  --storage="\$STORAGE" \\
  --bucket="\$BUCKET" \\
  --cache-dir="\$CACHE_DIR" \\
  --free-space-ratio="\$FREE_SPACE_RATIO" \\
  --cache-eviction="\$CACHE_EVICTION" \\
  --metrics="\$METRICS_ADDR" \\
  -o allow_other \\
  --no-syslog

# Empty means the whole filesystem was asked for, and the flag would reject an
# empty value.
if [ -n "\$SUB_PATH" ]; then
  set -- "\$@" --subdir="\$SUB_PATH"
fi

exec /usr/local/bin/juicefs mount "\$METAURL" "\$MOUNT_PATH" "\$@"
'
EOF
}

render_unit_file() {
  cat <<EOF
[Unit]
Description=JuiceFS host mount of the kube ai hub model volume
Documentation=https://juicefs.com/docs/community/introduction
# The client comes from an image, so Docker has to be up first. Nothing else
# depends on this unit, and a failure here is not fatal: the cluster reaches the
# same volume through the CSI driver, so the node stays usable either way.
Requires=${DOCKER_SERVICE}
After=${DOCKER_SERVICE} network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/bin/mkdir -p ${MOUNT_PATH} ${CACHE_DIR}
ExecStart=${MOUNT_SCRIPT}
# Stopping the container tears the FUSE mount down, but a stale mount point would
# silently hide the volume and send writes to the local disk, so unmounting is
# the belt to that braces.
ExecStop=/bin/sh -c '${DOCKER} rm -f ${CONTAINER_NAME} >/dev/null 2>&1; umount -l ${MOUNT_PATH} || true'
Restart=on-failure
RestartSec=10
KillMode=control-group

[Install]
WantedBy=multi-user.target
EOF
}

render_env_file() {
  cat <<EOF
# Environment for the host mount of the ${VOLUME_NAME} JuiceFS volume: the client
# credentials plus where it mounts and caches. Written by juicefs-host-mount.sh,
# handed to the container by Docker, and regenerated every time the script runs.
#
# 0600 on purpose. These keys reach the whole volume.
METAURL=${METAURL}
VOLUME_NAME=${VOLUME_NAME}
STORAGE=${STORAGE}
BUCKET=${BUCKET}
ACCESS_KEY=${ACCESS_KEY}
SECRET_KEY=${SECRET_KEY}
SUB_PATH=${SUB_PATH}
MOUNT_PATH=${MOUNT_PATH}
CACHE_DIR=${CACHE_DIR}
FREE_SPACE_RATIO=${FREE_SPACE_RATIO}
CACHE_EVICTION=${CACHE_EVICTION}
METRICS_ADDR=${METRICS_ADDR}
EOF
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------

# allow_other is what lets a user other than root enter the mount, and libfuse
# only permits it when fuse.conf says so.
ensure_fuse_conf() {
  if [ -f "$FUSE_CONF" ] && grep -Eq '^[[:space:]]*user_allow_other' "$FUSE_CONF"; then
    return 0
  fi
  log "   adding user_allow_other to ${FUSE_CONF}"
  if [ "$DRY_RUN" = "true" ]; then
    log "--- would append user_allow_other to ${FUSE_CONF}"
    return 0
  fi
  mkdir -p "$(dirname "$FUSE_CONF")"
  printf '%s\n' "user_allow_other" >> "$FUSE_CONF"
}

write_file() {
  local path="$1" content="$2" mode="$3" redact="${4:-false}"
  if [ "$DRY_RUN" = "true" ]; then
    log "--- would write ${path} (mode ${mode})"
    if [ "$redact" = "true" ]; then
      # Keep the shape of the rendered file visible without spilling the object
      # store keys into a terminal or a shared log.
      printf '%s\n' "$content" | sed -E 's/^((ACCESS|SECRET)_KEY=).*/\1<redacted>/'
    else
      printf '%s\n' "$content"
    fi
    return 0
  fi
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" > "$path"
  chmod "$mode" "$path"
}

uninstall_mount() {
  require_root
  log "== removing the host mount"

  if [ "$DRY_RUN" = "true" ]; then
    log "--- would disable and remove ${UNIT_FILE}"
    log "--- would stop and remove the ${CONTAINER_NAME} container"
    log "--- would remove ${ENV_FILE} and ${MOUNT_SCRIPT}"
    log "--- would unmount ${MOUNT_PATH} if mounted"
  else
    if command -v systemctl >/dev/null 2>&1; then
      systemctl disable --now "${UNIT_NAME}.service" >/dev/null 2>&1 || true
      rm -f "$UNIT_FILE"
      systemctl daemon-reload
    fi
    if command -v "$DOCKER" >/dev/null 2>&1; then
      "$DOCKER" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi
    rm -f "$ENV_FILE" "$MOUNT_SCRIPT"
    # Unmount rather than rmdir: leaving a stale directory in place would hide
    # the volume and silently write to the local disk instead of it.
    if mountpoint -q "$MOUNT_PATH" 2>/dev/null; then
      umount "$MOUNT_PATH" || warn "could not unmount ${MOUNT_PATH}"
    fi
  fi

  log "== done. The volume and ${CACHE_DIR} were not touched."
}

install_mount() {
  require_root
  [ -n "$IMAGE" ] || IMAGE="$(discover_image)"

  log "== mounting the JuiceFS volume on this node"

  log "-- reading the volume credentials"
  read_volume_secret
  log "   secret:   ${NAMESPACE}/${SECRET_NAME}"
  log "   image:    ${IMAGE}"

  log "-- resolving cluster Services to addresses"
  METAURL=$(resolve_cluster_host "$METAURL")
  BUCKET=$(resolve_cluster_host "$BUCKET")
  log "   metadata: $(printf '%s' "$METAURL" | sed 's#://[^:]*:#://<host>:#')"
  log "   bucket:   ${BUCKET}"

  if [ "$PVC" = "none" ]; then
    SUB_PATH=""
    log "-- exposing the whole filesystem"
  else
    resolve_sub_path
    log "-- exposing ${PVC} at the mount root (subdir ${SUB_PATH})"
  fi

  log "-- checking the container runtime"
  if [ "$DRY_RUN" = "true" ]; then
    log "--- would require ${DOCKER} and image ${IMAGE}"
  else
    command -v "$DOCKER" >/dev/null 2>&1 || die "$DOCKER is required to run the juicefs client"
    # Only pull when it is missing: on a cluster node the image is normally
    # already imported, and a pull would need registry credentials we do not have
    # here.
    if ! "$DOCKER" image inspect "$IMAGE" >/dev/null 2>&1; then
      log "   pulling ${IMAGE}"
      "$DOCKER" pull "$IMAGE" || die "cannot obtain ${IMAGE}; import it or pass --image"
    fi
  fi

  ensure_fuse_conf

  # The cache directory is shared with the cluster's own mounts on purpose:
  # JuiceFS stores blocks under a directory named after the volume UUID, so
  # pointing both at the same path means the host reads whatever the cluster
  # already downloaded instead of fetching it from MinIO again.
  write_file "$ENV_FILE" "$(render_env_file)" 0600 true
  write_file "$MOUNT_SCRIPT" "$(render_mount_script)" 0755
  write_file "$UNIT_FILE" "$(render_unit_file)" 0644

  if [ "$DRY_RUN" = "true" ]; then
    log "== dry run: nothing was changed"
    return 0
  fi

  command -v systemctl >/dev/null 2>&1 || die "systemctl is required"

  systemctl daemon-reload
  if [ "$NO_START" = "true" ]; then
    systemctl enable "${UNIT_NAME}.service" >/dev/null
    log "== enabled; start it with: systemctl start ${UNIT_NAME}"
    return 0
  fi

  log "-- starting the mount"
  systemctl enable "${UNIT_NAME}.service" >/dev/null
  # restart, not `--now`: the unit may already be running with an older
  # configuration, and `enable --now` would leave that one in place.
  systemctl restart "${UNIT_NAME}.service"

  # A first run has to fetch the client through the container runtime, so give it
  # more room than a restart would need before calling it a failure.
  local waited=0
  while [ "$waited" -lt 60 ]; do
    if mountpoint -q "$MOUNT_PATH"; then
      log "== mounted at ${MOUNT_PATH}"
      log "   models live under ${MOUNT_PATH}/<namespace>/<name>, for example"
      log "   ${MOUNT_PATH}/admin/Qwen3.5-2B"
      log "   logs: journalctl -u ${UNIT_NAME} -f"
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done

  warn "the unit is running but ${MOUNT_PATH} is not a mount point yet"
  warn "check: systemctl status ${UNIT_NAME}; journalctl -u ${UNIT_NAME} -n 50"
  die "the mount did not come up"
}

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    --mount-path)         MOUNT_PATH="${2:-}"; shift 2 ;;
    --cache-dir)          CACHE_DIR="${2:-}"; shift 2 ;;
    --storage-class)      STORAGE_CLASS="${2:-}"; shift 2 ;;
    --pvc)                PVC="${2:-}"; shift 2 ;;
    --secret)             SECRET_NAME="${2:-}"; shift 2 ;;
    --namespace)          NAMESPACE="${2:-}"; shift 2 ;;
    --image)              IMAGE="${2:-}"; shift 2 ;;
    --free-space-ratio)   FREE_SPACE_RATIO="${2:-}"; shift 2 ;;
    --cache-eviction)     CACHE_EVICTION="${2:-}"; shift 2 ;;
    --fuse-conf)          FUSE_CONF="${2:-}"; shift 2 ;;
    --no-start)           NO_START="true"; shift ;;
    --uninstall)          UNINSTALL="true"; shift ;;
    --dry-run)            DRY_RUN="true"; shift ;;
    -h|--help)            usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

[ -n "$MOUNT_PATH" ] || die "--mount-path cannot be empty"
[ -n "$CACHE_DIR" ] || die "--cache-dir cannot be empty"
[ -n "$STORAGE_CLASS" ] || die "--storage-class cannot be empty"

# The unit needs the exact unit name of the container runtime, which depends on
# how it was packaged. Derive it from the command that will actually be used.
DOCKER_SERVICE="${DOCKER_SERVICE:-$(basename "$DOCKER").service}"

if [ "$UNINSTALL" = "true" ]; then
  uninstall_mount
else
  install_mount
fi

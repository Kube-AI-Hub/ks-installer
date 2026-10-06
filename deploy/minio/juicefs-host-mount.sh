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
# Why the host can reach the volume at all:
#   - JuiceFS needs the metadata database and the object store. This runs on a
#     cluster node, where the Service ClusterIPs are routable, so both are
#     addressed by IP. The node's resolver is systemd-resolved and does not
#     resolve *.svc.cluster.local names, so names cannot be used.
#   - The juicefs client ships inside the mount image as a statically linked
#     binary, so it is copied out of the image rather than installed from a
#     package. Nothing else from the image is needed.
#
# Usage:
#   juicefs-host-mount.sh [options]
#
# Run with --help for the option list.

set -euo pipefail

KUBECTL="${KUBECTL:-kubectl}"
DOCKER="${DOCKER:-docker}"

CONFIG_DIR="/etc/juicefs"
BINARY_PATH="/usr/local/bin/juicefs"
UNIT_NAME="juicefs-kubeaihub"
MOUNT_SCRIPT="/usr/local/bin/${UNIT_NAME}-mount"
LOG_PATH="/var/log/${UNIT_NAME}.log"

# Defaults are the ones the storage foundation installs, so a plain run on a
# standard cluster needs no options at all. The credentials come from the
# StorageClass rather than from a guessed Secret name: the CSI parameters on the
# class name the Secret and its namespace, so a renamed release cannot leave this
# script reading the wrong object.
STORAGE_CLASS="juicefs-shared"
NAMESPACE=""
SECRET_NAME=""
MOUNT_PATH="/data1/kube-ai-hub/models"
CACHE_DIR="/data1/juicefs-cache"
IMAGE=""
FUSE_CONF="/etc/fuse.conf"

FREE_SPACE_RATIO="0.1"
CACHE_EVICTION="2-random"

DRY_RUN="false"
UNINSTALL="false"
UPDATE_BINARY="false"
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
  --secret <name>           Volume Secret, if it is not the one the
                            StorageClass points at.
  --namespace <ns>          Namespace of the volume Secret, overriding the one
                            recorded on the StorageClass.
  --image <img>             Image to take the juicefs client out of. Defaults to
                            $JUICEFS_MOUNT_IMAGE, else the tag the chart ships.
  --free-space-ratio <r>    Stop caching once the filesystem holding the cache
                            is this full (default 0.1).
  --cache-eviction <mode>   Cache eviction policy, none or 2-random
                            (default 2-random).
  --fuse-conf <file>        Created with user_allow_other so users other than
                            root can enter the mount (default /etc/fuse.conf).
                            Pass "none" to leave it alone.
  --update-binary           Re-copy the juicefs client even if one is already
                            installed. Use after upgrading the CSI image.
  --no-start                Write the configuration but do not start the unit.
  --uninstall               Stop and remove the unit and its configuration. The
                            data in the volume is not touched, and neither is
                            the cache directory.
  --dry-run                 Print what would be written instead of writing it.
  -h, --help                Show this help.

Notes:
  - Run as root: the mount is visible to the whole node and the unit is a system
    unit.
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
# The node reaches cluster Services by address but cannot resolve their names:
# its resolver is systemd-resolved, which knows nothing about cluster DNS. The
# namespace comes from the URL itself when it is a fully qualified
# "<service>.<namespace>.svc" name, so the metadata database and the object store
# do not have to live in the same namespace as the Secret.
resolve_cluster_host() {
  local url="$1"
  local host_port
  host_port=$(printf '%s' "$url" | sed -n 's#^[a-z0-9]*://\([^/]*\).*#\1#p')
  [ -n "$host_port" ] || { printf '%s' "$url"; return 0; }

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

# The mount image ships the juicefs client; nothing else is needed from it.
default_image() {
  if [ -n "${JUICEFS_MOUNT_IMAGE:-}" ]; then
    printf '%s' "$JUICEFS_MOUNT_IMAGE"
    return 0
  fi
  printf '%s' "docker.io/juicedata/mount:ce-v1.2.0"
}

# ---------------------------------------------------------------------------
# Rendered files
# ---------------------------------------------------------------------------

render_mount_script() {
  cat <<EOF
#!/bin/sh
# Copyright 2026 Kube AI Hub.
#
# Written by juicefs-host-mount.sh. Runs the JuiceFS client for the host mount.
# Kept as a script rather than a long ExecStart so the credentials stay in one
# file and shell quoting stays readable.
set -eu

. ${CONFIG_DIR}/${UNIT_NAME}.env

# --no-syslog keeps the client off the host's syslog and --log puts it somewhere
# an operator can find without journald.
exec ${BINARY_PATH} mount "\$METAURL" ${MOUNT_PATH} \\
  --storage="\$STORAGE" \\
  --bucket="\$BUCKET" \\
  --access-key="\$ACCESS_KEY" \\
  --secret-key="\$SECRET_KEY" \\
  --cache-dir=${CACHE_DIR} \\
  --free-space-ratio=${FREE_SPACE_RATIO} \\
  --cache-eviction=${CACHE_EVICTION} \\
  -o allow_other \\
  --no-syslog \\
  --log=${LOG_PATH}
EOF
}

render_unit_file() {
  cat <<EOF
[Unit]
Description=JuiceFS host mount of the kube ai hub model volume
Documentation=https://juicefs.com/docs/community/introduction
# Ordered only after the network, and intentionally not a dependency of
# anything: the cluster reaches this same volume through the CSI driver, so a
# mount failure here must leave the node usable rather than block it.
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/bin/mkdir -p ${MOUNT_PATH}
ExecStart=${MOUNT_SCRIPT}
ExecStop=/bin/sh -c 'umount ${MOUNT_PATH} || true'
Restart=on-failure
RestartSec=10
# The FUSE child is the mount; killing the supervisor alone would leave it
# behind, which is why the stop path unmounts explicitly.
KillMode=control-group

[Install]
WantedBy=multi-user.target
EOF
}

render_env_file() {
  cat <<EOF
# Credentials for the host mount of the ${VOLUME_NAME} JuiceFS volume.
# Written by juicefs-host-mount.sh. Change the chart or the release instead of
# editing this file; re-running the script regenerates it.
METAURL=${METAURL}
VOLUME_NAME=${VOLUME_NAME}
STORAGE=${STORAGE}
BUCKET=${BUCKET}
ACCESS_KEY=${ACCESS_KEY}
SECRET_KEY=${SECRET_KEY}
EOF
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------

install_binary() {
  if [ -x "$BINARY_PATH" ] && [ "$UPDATE_BINARY" != "true" ]; then
    log "   juicefs client already at ${BINARY_PATH} (use --update-binary to refresh)"
    return 0
  fi
  command -v "$DOCKER" >/dev/null 2>&1 \
    || die "docker is required to take the juicefs client out of ${IMAGE}"

  log "   extracting the juicefs client from ${IMAGE}"
  local container="${UNIT_NAME}-extract-$$"
  "$DOCKER" rm -f "$container" >/dev/null 2>&1 || true
  # `create` rather than `run`: nothing in the image needs to execute.
  "$DOCKER" create --name "$container" "$IMAGE" >/dev/null
  "$DOCKER" cp "${container}:/usr/local/bin/juicefs" "$BINARY_PATH" >/dev/null
  "$DOCKER" rm -f "$container" >/dev/null 2>&1 || true
  chmod 0755 "$BINARY_PATH"
  log "   installed $("$BINARY_PATH" version 2>/dev/null | head -n 1 || echo "$BINARY_PATH")"
}

# allow_other is what lets a user other than root enter the mount.
ensure_fuse_conf() {
  [ "$FUSE_CONF" = "none" ] && return 0
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
  local path="$1" content="$2" mode="$3"
  if [ "$DRY_RUN" = "true" ]; then
    log "--- would write ${path} (mode ${mode})"
    printf '%s\n' "$content"
    return 0
  fi
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" > "$path"
  chmod "$mode" "$path"
}

uninstall_mount() {
  require_root
  log "== removing the host mount"

  if command -v systemctl >/dev/null 2>&1; then
    if [ "$DRY_RUN" = "true" ]; then
      log "--- would disable and remove /etc/systemd/system/${UNIT_NAME}.service"
    else
      systemctl disable --now "${UNIT_NAME}.service" >/dev/null 2>&1 || true
      rm -f "/etc/systemd/system/${UNIT_NAME}.service"
      systemctl daemon-reload
    fi
  fi

  if [ "$DRY_RUN" = "true" ]; then
    log "--- would remove ${CONFIG_DIR}/${UNIT_NAME}.env and ${MOUNT_SCRIPT}"
    log "--- would unmount ${MOUNT_PATH} if mounted"
  else
    rm -f "${CONFIG_DIR}/${UNIT_NAME}.env" "$MOUNT_SCRIPT"
    # Unmount rather than rmdir: leaving a stale directory in place would hide
    # file:///data1/kube-ai-hub/models and silently write to the local disk
    # instead of the volume.
    if mountpoint -q "$MOUNT_PATH" 2>/dev/null; then
      umount "$MOUNT_PATH" || warn "could not unmount ${MOUNT_PATH}"
    fi
  fi

  log "== done. The volume and ${CACHE_DIR} were not touched."
}

install_mount() {
  require_root
  [ -n "$IMAGE" ] || IMAGE="$(default_image)"

  log "== mounting the JuiceFS volume on this node"

  log "-- reading the volume credentials"
  read_volume_secret
  log "   secret:   ${NAMESPACE}/${SECRET_NAME}"

  log "-- resolving cluster Services to addresses"
  METAURL=$(resolve_cluster_host "$METAURL")
  BUCKET=$(resolve_cluster_host "$BUCKET")
  log "   metadata: $(printf '%s' "$METAURL" | sed 's#://[^:]*:#://<host>:#')"
  log "   bucket:   ${BUCKET}"

  log "-- preparing the juicefs client"
  if [ "$DRY_RUN" = "true" ]; then
    log "--- would extract ${BINARY_PATH} from ${IMAGE}"
  else
    install_binary
  fi

  ensure_fuse_conf

  if [ "$DRY_RUN" = "true" ]; then
    log "--- would create ${CACHE_DIR} and ${MOUNT_PATH}"
  else
    mkdir -p "$CACHE_DIR" "$MOUNT_PATH"
  fi

  # The cache directory is shared with the cluster's own mounts on purpose:
  # JuiceFS stores blocks under a directory named after the volume UUID, so
  # pointing both at the same path means the host reads whatever the cluster
  # already downloaded instead of fetching it from MinIO again.
  write_file "${CONFIG_DIR}/${UNIT_NAME}.env" "$(render_env_file)" 0600
  write_file "$MOUNT_SCRIPT" "$(render_mount_script)" 0755
  write_file "/etc/systemd/system/${UNIT_NAME}.service" "$(render_unit_file)" 0644

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
  systemctl enable --now "${UNIT_NAME}.service" >/dev/null
  sleep 3

  if mountpoint -q "$MOUNT_PATH"; then
    log "== mounted at ${MOUNT_PATH}"
    log "   models live under ${MOUNT_PATH}/<namespace>/<name>, for example"
    log "   ${MOUNT_PATH}/admin/Qwen3.5-2B"
    log "   logs: journalctl -u ${UNIT_NAME} -f   or   ${LOG_PATH}"
  else
    warn "the unit started but ${MOUNT_PATH} is not a mount point yet"
    warn "check: systemctl status ${UNIT_NAME}; tail ${LOG_PATH}"
    die "the mount did not come up"
  fi
}

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    --mount-path)         MOUNT_PATH="${2:-}"; shift 2 ;;
    --cache-dir)          CACHE_DIR="${2:-}"; shift 2 ;;
    --storage-class)      STORAGE_CLASS="${2:-}"; shift 2 ;;
    --secret)             SECRET_NAME="${2:-}"; shift 2 ;;
    --namespace)          NAMESPACE="${2:-}"; shift 2 ;;
    --image)              IMAGE="${2:-}"; shift 2 ;;
    --free-space-ratio)   FREE_SPACE_RATIO="${2:-}"; shift 2 ;;
    --cache-eviction)     CACHE_EVICTION="${2:-}"; shift 2 ;;
    --fuse-conf)          FUSE_CONF="${2:-}"; shift 2 ;;
    --update-binary)      UPDATE_BINARY="true"; shift ;;
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

if [ "$UNINSTALL" = "true" ]; then
  uninstall_mount
else
  install_mount
fi

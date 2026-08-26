#!/usr/bin/env bash
# Repair GPU PrometheusRules and notification-manager on an already-installed cluster.
#
# Standalone: copy this file anywhere. Only kubectl is required (helm is used
# locally if present; otherwise helm runs inside the ks-installer pod).
# A ks-installer git checkout is optional.
#
# Asset resolution, first match wins:
#   1) CHART_DIR / GPU_RULES_DIR / GPU_MONITOR_DIR if set
#   2) KS_INSTALLER_DIR, or this script living inside a ks-installer checkout
#   3) files copied from the Running ks-installer pod
#   4) chart rebuilt from the helm release Secret (helm upgrade only)
#
# Use when ks-monitor failed at:
#   notification-manager | Deploying notification-manager
#   helm upgrade ... post-upgrade hooks failed: BackoffLimitExceeded
# and cluster-gpu-k8s-rules / pod:gpu_* recording rules are missing.
#
# Prerequisites:
#   - kubectl on PATH, kubeconfig pointing at the cluster
#   - kube-ai-hub/kubectl:v1.33.4-kah (or later) is a real multi-arch image
#     (arm64 binary ELF e_machine 0xb7). Pull the new digest before upgrading.
#
# Usage:
#   ./repair-gpu-notification-manager.sh
#   SKIP_HELM=1 ./repair-gpu-notification-manager.sh   # GPU rules only
set -euo pipefail

NS="${NS:-kubesphere-monitoring-system}"
INSTALLER_NS="${INSTALLER_NS:-kubesphere-system}"
INSTALLER_CONTAINER="${INSTALLER_CONTAINER:-installer}"
SKIP_HELM="${SKIP_HELM:-0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/nm-repair.XXXXXX")"
cleanup() { rm -rf "${WORKDIR}"; }
trap cleanup EXIT

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing command: $1" >&2
    exit 1
  }
}

need_cmd kubectl

detect_local_installer() {
  if [[ -n "${KS_INSTALLER_DIR:-}" ]]; then
    printf '%s\n' "${KS_INSTALLER_DIR}"
    return 0
  fi
  local candidate="${SCRIPT_DIR}/.."
  if [[ -d "${candidate}/roles/ks-monitor/files/prometheus/gpu" ]]; then
    (cd "${candidate}" && pwd)
    return 0
  fi
  return 1
}

find_installer_pod() {
  if [[ -n "${INSTALLER_POD:-}" ]]; then
    printf '%s\n' "${INSTALLER_POD}"
    return 0
  fi
  local pod
  pod="$(kubectl -n "${INSTALLER_NS}" get pod -l app=ks-installer \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "${pod}" ]]; then
    return 1
  fi
  printf '%s\n' "${pod}"
}

installer_exec() {
  kubectl -n "${INSTALLER_NS}" exec "${INSTALLER_POD}" -c "${INSTALLER_CONTAINER}" -- "$@"
}

extract_from_installer_pod() {
  local dest="$1"
  local files_root=/kubesphere/installer/roles/ks-monitor/files
  echo "== copy files from pod ${INSTALLER_NS}/${INSTALLER_POD} =="
  mkdir -p "${dest}"
  installer_exec sh -c "
    cd '${files_root}' || exit 1
    paths=
    for d in prometheus/gpu gpu-monitoring notification-manager; do
      [ -e \"\$d\" ] && paths=\"\$paths \$d\"
    done
    [ -n \"\$paths\" ] || { echo 'ks-monitor files missing in installer image' >&2; exit 1; }
    tar -cf - \$paths
  " | tar -xf - -C "${dest}"
}

extract_chart_from_helm_release() {
  local dest="$1"
  need_cmd python3
  echo "== rebuild chart from helm release Secret =="
  local secret
  secret="$(kubectl -n "${NS}" get secret -l owner=helm,name=notification-manager \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true)"
  if [[ -z "${secret}" ]]; then
    echo "no helm release Secret for notification-manager in ${NS}" >&2
    return 1
  fi
  kubectl -n "${NS}" get secret "${secret}" -o jsonpath='{.data.release}' \
    | python3 - "${dest}" <<'PY'
import base64, gzip, json, pathlib, sys

raw = sys.stdin.buffer.read().strip()
data = raw
for _ in range(2):
    try:
        data = base64.b64decode(data)
    except Exception:
        break
if data[:2] == b"\x1f\x8b":
    data = gzip.decompress(data)
rel = json.loads(data)
chart = rel.get("chart") or {}
out = pathlib.Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)

def blob(item):
    raw = item.get("data", b"")
    if isinstance(raw, str):
        try:
            return base64.b64decode(raw)
        except Exception:
            return raw.encode("utf-8")
    return raw

for item in chart.get("templates") or []:
    name = item.get("name") or ""
    if not name or name.endswith("tls.yaml"):
        continue
    path = out / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(blob(item))

for item in chart.get("files") or []:
    name = item.get("name") or ""
    if not name:
        continue
    path = out / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(blob(item))

meta = chart.get("metadata") or {}
chart_yaml = out / "Chart.yaml"
if not chart_yaml.exists():
    lines = []
    for k in ("apiVersion", "name", "version", "appVersion", "description"):
        if meta.get(k) is not None:
            lines.append("%s: %s" % (k, meta[k]))
    chart_yaml.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
}

prepare_chart() {
  local chart="$1"
  [[ -d "${chart}/templates" ]] || return 1
  rm -f "${chart}/templates/tls.yaml"
  if [[ -f "${chart}/Chart.yaml" ]] && grep -q '^version: 2.3.0$' "${chart}/Chart.yaml"; then
    local tmp="${chart}/Chart.yaml.bak"
    sed 's/^version: 2.3.0$/version: 2.3.1/' "${chart}/Chart.yaml" > "${tmp}"
    mv "${tmp}" "${chart}/Chart.yaml"
  fi
}

resolve_assets() {
  local files_root local_root
  local need_gpu=0 need_chart=0
  [[ -d "${GPU_RULES_DIR:-}" ]] || need_gpu=1
  if [[ "${SKIP_HELM}" != "1" && ! -d "${CHART_DIR:-}/templates" ]]; then
    need_chart=1
  fi

  if [[ "${need_gpu}" -eq 1 || "${need_chart}" -eq 1 ]]; then
    if local_root="$(detect_local_installer)"; then
      echo "== using local ks-installer ${local_root} =="
      GPU_RULES_DIR="${GPU_RULES_DIR:-${local_root}/roles/ks-monitor/files/prometheus/gpu}"
      GPU_MONITOR_DIR="${GPU_MONITOR_DIR:-${local_root}/roles/ks-monitor/files/gpu-monitoring}"
      CHART_DIR="${CHART_DIR:-${local_root}/roles/ks-monitor/files/notification-manager}"
    elif INSTALLER_POD="$(find_installer_pod)"; then
      files_root="${WORKDIR}/from-pod"
      extract_from_installer_pod "${files_root}"
      GPU_RULES_DIR="${GPU_RULES_DIR:-${files_root}/prometheus/gpu}"
      GPU_MONITOR_DIR="${GPU_MONITOR_DIR:-${files_root}/gpu-monitoring}"
      CHART_DIR="${CHART_DIR:-${files_root}/notification-manager}"
    fi
  fi

  if [[ "${SKIP_HELM}" != "1" && ! -d "${CHART_DIR:-}/templates" ]]; then
    CHART_DIR="${WORKDIR}/from-helm"
    extract_chart_from_helm_release "${CHART_DIR}" || CHART_DIR=""
  fi

  if [[ ! -d "${GPU_RULES_DIR:-}" ]]; then
    echo "GPU rules not found. Set GPU_RULES_DIR, run from a ks-installer checkout, or ensure ks-installer is Running." >&2
    exit 1
  fi
}

helm_upgrade() {
  local chart="$1"
  prepare_chart "${chart}"
  if [[ -f "${chart}/templates/tls.yaml" ]]; then
    echo "tls.yaml is still in the chart; refuse to upgrade a duplicate Secret" >&2
    exit 1
  fi

  local helm_args=(upgrade --install notification-manager "${chart}" --namespace "${NS}" --timeout 5m --wait=false)
  if command -v helm >/dev/null 2>&1; then
    if helm status notification-manager -n "${NS}" >/dev/null 2>&1; then
      helm_args+=(--reuse-values)
    elif [[ -n "${VALUES_FILE:-}" ]]; then
      helm_args+=(-f "${VALUES_FILE}")
    else
      echo "no existing release; set VALUES_FILE to custom-values-notification.yaml" >&2
      exit 1
    fi
    echo "== helm upgrade --install notification-manager (local helm) =="
    helm "${helm_args[@]}"
    return 0
  fi

  if [[ -z "${INSTALLER_POD:-}" ]]; then
    INSTALLER_POD="$(find_installer_pod || true)"
  fi
  if [[ -z "${INSTALLER_POD:-}" ]]; then
    echo "helm not on PATH and ks-installer pod not found" >&2
    exit 1
  fi

  echo "== helm upgrade inside ${INSTALLER_NS}/${INSTALLER_POD} =="
  local remote=/tmp/nm-repair-chart
  installer_exec rm -rf "${remote}"
  installer_exec mkdir -p "${remote}"
  tar -C "${chart}" -cf - . | kubectl -n "${INSTALLER_NS}" exec -i "${INSTALLER_POD}" -c "${INSTALLER_CONTAINER}" -- tar -xf - -C "${remote}"
  if installer_exec helm status notification-manager -n "${NS}" >/dev/null 2>&1; then
    installer_exec helm upgrade --install notification-manager "${remote}" \
      --namespace "${NS}" --timeout 5m --wait=false --reuse-values
  elif [[ -n "${VALUES_FILE:-}" ]]; then
    kubectl -n "${INSTALLER_NS}" cp "${VALUES_FILE}" "${INSTALLER_POD}:${remote}/values-repair.yaml" -c "${INSTALLER_CONTAINER}"
    installer_exec helm upgrade --install notification-manager "${remote}" \
      --namespace "${NS}" --timeout 5m --wait=false -f "${remote}/values-repair.yaml"
  else
    echo "no existing release; set VALUES_FILE, or install helm locally" >&2
    exit 1
  fi
}

resolve_assets

echo "== apply GPU PrometheusRules =="
kubectl apply -f "${GPU_RULES_DIR}"

echo "== drop overlapping compat PrometheusRules =="
kubectl -n "${NS}" delete prometheusrule \
  kube-ai-hub-hami-gpu-compat \
  kube-ai-hub-gpu-compat-rules \
  --ignore-not-found

if [[ -f "${GPU_MONITOR_DIR:-}/gpu-agent-service-monitor.yaml" ]]; then
  echo "== apply fallback gpu-agent ServiceMonitor =="
  kubectl apply -f "${GPU_MONITOR_DIR}/gpu-agent-service-monitor.yaml"
fi
if [[ -d "${GPU_MONITOR_DIR:-}/gpu-dashboards" ]]; then
  echo "== apply GPU dashboards =="
  kubectl apply -f "${GPU_MONITOR_DIR}/gpu-dashboards" || true
fi

echo "== PrometheusRule =="
kubectl get prometheusrule -n "${NS}" | grep -E 'NAME|gpu|npu|dcu|mlu|xpu|ppu|gcu' || true

if [[ "${SKIP_HELM}" == "1" ]]; then
  echo "SKIP_HELM=1, done"
  exit 0
fi

if [[ ! -d "${CHART_DIR:-}/templates" ]]; then
  echo "notification-manager chart not found. Set CHART_DIR or ensure ks-installer / helm release exists." >&2
  exit 1
fi

# Mutate a copy so a local checkout is not rewritten.
if [[ "${CHART_DIR}" != "${WORKDIR}"/* ]]; then
  mkdir -p "${WORKDIR}/chart"
  cp -a "${CHART_DIR}/." "${WORKDIR}/chart/"
  CHART_DIR="${WORKDIR}/chart"
fi

echo "== notification-manager helm status (before) =="
if command -v helm >/dev/null 2>&1; then
  helm list -n "${NS}" -f '^notification-manager$' || true
else
  echo "(local helm missing; will use ks-installer pod)"
fi

helm_upgrade "${CHART_DIR}"

echo "== patch CRD conversion caBundle from ValidatingWebhook =="
cabundle="$(kubectl get validatingwebhookconfiguration notification-manager-validating-webhook -o jsonpath='{.webhooks[0].clientConfig.caBundle}' || true)"
if [[ -n "${cabundle}" ]]; then
  kubectl patch crd configs.notification.kubesphere.io --type=merge \
    -p "{\"spec\":{\"conversion\":{\"webhook\":{\"clientConfig\":{\"caBundle\":\"${cabundle}\"}}}}}"
  kubectl patch crd receivers.notification.kubesphere.io --type=merge \
    -p "{\"spec\":{\"conversion\":{\"webhook\":{\"clientConfig\":{\"caBundle\":\"${cabundle}\"}}}}}"
else
  echo "webhook caBundle empty; skip CRD patch (hook Job should fill it)"
fi

echo "== notification-manager helm status (after) =="
if command -v helm >/dev/null 2>&1; then
  helm history notification-manager -n "${NS}" --max 5
else
  installer_exec helm history notification-manager -n "${NS}" --max 5
fi
kubectl -n "${NS}" get deploy,po -l 'control-plane=controller-manager' || \
  kubectl -n "${NS}" get deploy notification-manager-operator notification-manager-deployment

echo "Done. If helm STATUS is still failed, check:"
echo "  1) hook image kubectl arch: kubectl -n ${NS} get job"
echo "  2) crictl/nerdctl inspect kube-ai-hub/kubectl:v1.33.4-kah ELF e_machine (arm64=b7 00)"
echo "  3) then re-run this script after pulling the fixed image"

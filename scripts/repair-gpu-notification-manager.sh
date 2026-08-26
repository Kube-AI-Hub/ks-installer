#!/usr/bin/env bash
# Repair GPU PrometheusRules and notification-manager on an already-installed cluster.
#
# Use when ks-monitor failed at:
#   notification-manager | Deploying notification-manager
#   helm upgrade ... post-upgrade hooks failed: BackoffLimitExceeded
# and cluster-gpu-k8s-rules / pod:gpu_* recording rules are missing.
#
# Prerequisites:
#   - kubectl and helm on PATH, kubeconfig pointing at the cluster
#   - kube-ai-hub/kubectl:v1.33.4-kah (or later) is a real multi-arch image
#     (arm64 binary ELF e_machine 0xb7). Pull the new digest before upgrading.
#
# Usage:
#   ./scripts/repair-gpu-notification-manager.sh
#   SKIP_HELM=1 ./scripts/repair-gpu-notification-manager.sh   # GPU rules only
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="${NS:-kubesphere-monitoring-system}"
CHART_DIR="${ROOT_DIR}/roles/ks-monitor/files/notification-manager"
GPU_RULES_DIR="${ROOT_DIR}/roles/ks-monitor/files/prometheus/gpu"
GPU_MONITOR_DIR="${ROOT_DIR}/roles/ks-monitor/files/gpu-monitoring"
SKIP_HELM="${SKIP_HELM:-0}"

if [[ ! -d "${CHART_DIR}/templates" ]]; then
  echo "chart not found: ${CHART_DIR}" >&2
  exit 1
fi
if [[ -f "${CHART_DIR}/templates/tls.yaml" ]]; then
  echo "tls.yaml is still in the chart; refuse to upgrade a duplicate Secret" >&2
  exit 1
fi

echo "== apply GPU PrometheusRules =="
kubectl apply -f "${GPU_RULES_DIR}"

if [[ -f "${GPU_MONITOR_DIR}/gpu-agent-service-monitor.yaml" ]]; then
  echo "== apply fallback gpu-agent ServiceMonitor =="
  kubectl apply -f "${GPU_MONITOR_DIR}/gpu-agent-service-monitor.yaml"
fi
if [[ -d "${GPU_MONITOR_DIR}/gpu-dashboards" ]]; then
  echo "== apply GPU dashboards =="
  kubectl apply -f "${GPU_MONITOR_DIR}/gpu-dashboards" || true
fi

echo "== PrometheusRule =="
kubectl get prometheusrule -n "${NS}" | grep -E 'NAME|gpu' || true

if [[ "${SKIP_HELM}" == "1" ]]; then
  echo "SKIP_HELM=1, done"
  exit 0
fi

echo "== notification-manager helm status (before) =="
helm list -n "${NS}" -f '^notification-manager$' || true

echo "== helm upgrade --install notification-manager 2.3.1 =="
helm_args=(upgrade --install notification-manager "${CHART_DIR}" --namespace "${NS}" --timeout 5m --wait=false)
if helm status notification-manager -n "${NS}" >/dev/null 2>&1; then
  helm_args+=(--reuse-values)
else
  echo "no existing release; pass VALUES_FILE=-f custom-values-notification.yaml" >&2
  if [[ -n "${VALUES_FILE:-}" ]]; then
    helm_args+=(-f "${VALUES_FILE}")
  else
    echo "set VALUES_FILE to the installer-rendered custom-values-notification.yaml" >&2
    exit 1
  fi
fi
helm "${helm_args[@]}"

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
helm history notification-manager -n "${NS}" --max 5
kubectl -n "${NS}" get deploy,po -l 'control-plane=controller-manager' || \
  kubectl -n "${NS}" get deploy notification-manager-operator notification-manager-deployment

echo "Done. If helm STATUS is still failed, check:"
echo "  1) hook image kubectl arch: kubectl -n ${NS} get job"
echo "  2) crictl/nerdctl inspect kube-ai-hub/kubectl:v1.33.4-kah ELF e_machine (arm64=b7 00)"
echo "  3) then re-run this script after pulling the fixed image"

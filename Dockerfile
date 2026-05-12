ARG SHELL_OPERATOR_IMAGE=watering-ai-registry.cn-shanghai.cr.aliyuncs.com/kube-ai-hub/shell-operator:v1.16.4-log-3
FROM ${SHELL_OPERATOR_IMAGE}

ENV ANSIBLE_ROLES_PATH=/kubesphere/installer/roles
ENV LOG_TYPE=color
WORKDIR /kubesphere
ADD controller/* /hooks/kubesphere/

ADD roles /kubesphere/installer/roles
ADD env /kubesphere/results/env
ADD playbooks /kubesphere/playbooks

USER kubesphere

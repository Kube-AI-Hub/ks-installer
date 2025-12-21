FROM watering-ai-registry.cn-shanghai.cr.aliyuncs.com/kube-ai-hub/shell-operator:v3.4.1

ENV  ANSIBLE_ROLES_PATH /kubesphere/installer/roles
WORKDIR /kubesphere
ADD controller/* /hooks/kubesphere/

ADD roles /kubesphere/installer/roles
ADD env /kubesphere/results/env
ADD playbooks /kubesphere/playbooks

USER kubesphere

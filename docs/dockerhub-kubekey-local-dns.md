# 为 CoreDNS / nodelocaldns 添加 dockerhub.kubekey.local 解析

KubeKey 私有仓库域名 `dockerhub.kubekey.local` 通常只写在节点 `/etc/hosts`（例如 `192.168.200.27 dockerhub.kubekey.local`）。

集群里的 Pod（含 Knative controller）走 **nodelocaldns `169.254.25.10`** 或 **CoreDNS `10.233.0.3`**，`forward` **不会读节点 `/etc/hosts`**。结果是：

```
lookup dockerhub.kubekey.local on 169.254.25.10:53: no such host
```

Knative 解析镜像 digest 时就会报 `ContainerMissing`，即使节点 Docker 里已经有镜像。

两边都要加一段独立的 `hosts` 区。把 `192.168.200.27` 换成实际仓库 VIP。

## 1. CoreDNS

编辑 `kube-system/coredns`，在 `.:53` **前面**加：

```
dockerhub.kubekey.local:53 {
  errors
  cache 30
  hosts {
    192.168.200.27 dockerhub.kubekey.local
  }
}
```

```bash
kubectl -n kube-system edit cm coredns
kubectl -n kube-system rollout restart deploy/coredns
kubectl -n kube-system rollout status deploy/coredns
```

## 2. nodelocaldns

编辑 `kube-system/nodelocaldns`，在 `cluster.local:53` **前面**加（必须 `bind 169.254.25.10`）：

```
dockerhub.kubekey.local:53 {
  errors
  cache 30
  hosts {
    192.168.200.27 dockerhub.kubekey.local
  }
  bind 169.254.25.10
}
```

```bash
kubectl -n kube-system edit cm nodelocaldns
kubectl -n kube-system rollout restart ds/nodelocaldns
kubectl -n kube-system rollout status ds/nodelocaldns
```

## 3. 验证

```bash
# nodelocaldns（大多数 Pod / Knative 用这个）
kubectl run dns-nld --rm -it --restart=Never --image=busybox:1.36 -- \
  nslookup dockerhub.kubekey.local 169.254.25.10

# CoreDNS
kubectl run dns-core --rm -it --restart=Never --image=busybox:1.36 -- \
  nslookup dockerhub.kubekey.local 10.233.0.3
```

都应返回 `Address: 192.168.200.27`。

## 注意

- 不要指望 `.` 区的 `forward . /etc/resolv.conf` 使用节点 hosts。
- 两个 ConfigMap 标签是 `addonmanager.kubernetes.io/mode: EnsureExists`，重装 addon 可能冲掉，需再加一次或写进安装清单。
- 解析通了之后，kubelet 仍要从该仓库拉镜像。若只在 Docker 里、不在 containerd，还需：

```bash
docker save dockerhub.kubekey.local/kube-ai-hub/opencsghq/vllm-ascend:v0.23.0-a3 \
  | ctr -n k8s.io images import -
```

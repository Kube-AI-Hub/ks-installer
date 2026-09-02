REPO?=watering-ai-registry.cn-shanghai.cr.aliyuncs.com/kube-ai-hub
TAG?=$(shell git rev-parse --abbrev-ref HEAD | sed -e 's/\//-/g')-dev-$(shell git rev-parse --short HEAD)
SHELL_OPERATOR_VERSION?=v1.16.4-log-3
FLUENT_BIT_VERSION?=v5.1.1-kah
CONTAINER_CLI?=docker
# Repo root (parent of ks-installer); required for Dockerfile.shelloperator COPY shell-operator/
REPO_ROOT:=$(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)

build:
	$(CONTAINER_CLI) build . --file Dockerfile --build-arg SHELL_OPERATOR_IMAGE=$(REPO)/shell-operator:$(TAG) --tag $(REPO)/ks-installer:$(TAG)
push:
	$(CONTAINER_CLI) push $(REPO)/ks-installer:$(TAG)
push-multiarch:
	$(CONTAINER_CLI) buildx build . --file Dockerfile --tag $(REPO)/ks-installer:$(TAG) --platform linux/amd64,linux/arm64 --push
all: build push

# Absolute -f so builds work when make is run from ks-installer/ (relative -f is cwd-based).
SHELL_OPERATOR_DOCKERFILE:=$(abspath $(dir $(lastword $(MAKEFILE_LIST)))/Dockerfile.shelloperator)
FLUENT_BIT_DIR:=$(abspath $(dir $(lastword $(MAKEFILE_LIST)))/build/fluent-bit)

build-shelloperator-multiarch:
	$(CONTAINER_CLI) buildx build $(REPO_ROOT) -f $(SHELL_OPERATOR_DOCKERFILE) --tag $(REPO)/shell-operator:$(SHELL_OPERATOR_VERSION) --platform linux/amd64,linux/arm64

push-shelloperator-multiarch:
	$(CONTAINER_CLI) buildx build $(REPO_ROOT) -f $(SHELL_OPERATOR_DOCKERFILE) --tag $(REPO)/shell-operator:$(SHELL_OPERATOR_VERSION) --platform linux/amd64,linux/arm64 --push

# fluent-bit with jemalloc 64KiB pages (Kylin v10 ARM64). See build/fluent-bit/.
push-fluent-bit-multiarch:
	cd $(FLUENT_BIT_DIR) && REGISTRY=$(REPO) VERSION=$(FLUENT_BIT_VERSION) DEBIAN_MIRROR=mirrors.aliyun.com ./build.sh

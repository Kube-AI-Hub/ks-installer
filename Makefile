REPO?=watering-ai-registry.cn-shanghai.cr.aliyuncs.com/kube-ai-hub
TAG?=$(shell git rev-parse --abbrev-ref HEAD | sed -e 's/\//-/g')-dev-$(shell git rev-parse --short HEAD)
CONTAINER_CLI?=docker

build:
	$(CONTAINER_CLI) build . --file Dockerfile --build-arg SHELL_OPERATOR_IMAGE=$(REPO)/shell-operator:$(TAG) --tag $(REPO)/ks-installer:$(TAG)
push:
	$(CONTAINER_CLI) push $(REPO)/ks-installer:$(TAG)
push-multiarch:
	$(CONTAINER_CLI) buildx build . --file Dockerfile --build-arg SHELL_OPERATOR_IMAGE=$(REPO)/shell-operator:$(TAG) --tag $(REPO)/ks-installer:$(TAG) --platform linux/amd64,linux/arm64 --push
all: build push

build-shelloperator-multiarch:
	$(CONTAINER_CLI) buildx build . --file Dockerfile.shelloperator --tag $(REPO)/shell-operator:$(TAG) --platform linux/amd64,linux/arm64

push-shelloperator-multiarch:
	$(CONTAINER_CLI) buildx build . --file Dockerfile.shelloperator --tag $(REPO)/shell-operator:$(TAG) --platform linux/amd64,linux/arm64 --push

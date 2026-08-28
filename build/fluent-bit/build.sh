#!/usr/bin/env bash
set -eu -o pipefail

# Multi-arch fluent-bit image with jemalloc 64KiB page support.
# Requires: docker buildx. For --push: docker login <registry>
#
# Examples:
#   ./build.sh
#   PLATFORMS=linux/arm64 DOCKER_PUSH=0 ./build.sh
#   DEBIAN_MIRROR=mirrors.aliyun.com ./build.sh
#   WATCHER_IMAGE=watering-ai-registry.cn-shanghai.cr.aliyuncs.com/kube-ai-hub/fluent-bit:v3.0.4 ./build.sh

REGISTRY="${REGISTRY:-watering-ai-registry.cn-shanghai.cr.aliyuncs.com/kube-ai-hub}"
IMG_NAME="${IMG_NAME:-fluent-bit}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
BUILDER_NAME="${BUILDER_NAME:-fluent-bit-kah-builder}"
FLUENT_BIT_VERSION="${FLUENT_BIT_VERSION:-5.1.1}"
WATCHER_IMAGE="${WATCHER_IMAGE:-watering-ai-registry.cn-shanghai.cr.aliyuncs.com/kube-ai-hub/fluent-bit:v3.0.4}"
RUNTIME_IMAGE="${RUNTIME_IMAGE:-watering-ai-registry.cn-shanghai.cr.aliyuncs.com/kube-ai-hub/fluent/fluent-bit:${FLUENT_BIT_VERSION}}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${ROOT_DIR}/VERSION" ]; then
    VERSION="${VERSION:-$(tr -d '\n' < "${ROOT_DIR}/VERSION")}"
fi
VERSION="${VERSION:-dev}"

IMG_TAG="${REGISTRY}/${IMG_NAME}:${VERSION}"

DOCKER_BUILDX_OUTPUT="--push"
if [[ "${PLATFORMS}" != *","* ]]; then
    if [[ "${DOCKER_PUSH:-1}" != "1" ]]; then
        DOCKER_BUILDX_OUTPUT="--load"
    fi
fi

echo "Building kube-ai-hub fluent-bit image: ${IMG_TAG}"
echo "Platforms: ${PLATFORMS}"
echo "Version: ${VERSION}"
echo "fluent-bit: ${FLUENT_BIT_VERSION}"
echo "runtime base: ${RUNTIME_IMAGE}"
echo "watcher source: ${WATCHER_IMAGE}"

if ! docker buildx version &>/dev/null; then
    echo "Error: docker buildx is required" >&2
    exit 1
fi

if ! docker buildx inspect "${BUILDER_NAME}" &>/dev/null; then
    echo "Creating buildx builder: ${BUILDER_NAME}"
    docker buildx create --name "${BUILDER_NAME}" --use
else
    docker buildx use "${BUILDER_NAME}"
fi

docker buildx inspect --bootstrap

cd "${ROOT_DIR}"

BUILD_ARGS=(
    --build-arg "FLUENT_BIT_VERSION=${FLUENT_BIT_VERSION}"
    --build-arg "WATCHER_IMAGE=${WATCHER_IMAGE}"
    --build-arg "RUNTIME_IMAGE=${RUNTIME_IMAGE}"
)

if [ -n "${FLUENT_BIT_TARBALL_URL:-}" ]; then
    BUILD_ARGS+=(--build-arg "FLUENT_BIT_TARBALL_URL=${FLUENT_BIT_TARBALL_URL}")
fi
if [ -n "${DEBIAN_MIRROR:-}" ]; then
    BUILD_ARGS+=(--build-arg "DEBIAN_MIRROR=${DEBIAN_MIRROR}")
fi

docker buildx build \
    --platform "${PLATFORMS}" \
    "${BUILD_ARGS[@]}" \
    --provenance=false \
    --sbom=false \
    --tag "${IMG_TAG}" \
    ${DOCKER_BUILDX_OUTPUT} \
    .

if [[ "${DOCKER_BUILDX_OUTPUT}" == "--push" ]]; then
    echo "Successfully built and pushed: ${IMG_TAG}"
    echo "Manifest:"
    docker buildx imagetools inspect "${IMG_TAG}"
else
    echo "Successfully built (loaded locally): ${IMG_TAG}"
fi

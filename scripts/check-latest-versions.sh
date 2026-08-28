#!/usr/bin/env bash

#==============================================================================
# LATEST VERSION PIN VALIDATION
#==============================================================================

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT

#==============================================================================
# MONITORING COMPONENT VALIDATION
#==============================================================================

validate_component() {
  local repository="$1"
  local image_repository="$2"
  local compose_version_prefix="$3"
  local latest_version
  local pinned_image
  local pinned_version
  local manifest

  latest_version=$(curl --fail --location --silent --show-error \
    "https://api.github.com/repos/$repository/releases/latest" | jq -r '.tag_name')
  pinned_image=$(sed -n "s|^[[:space:]]*image: $image_repository:\([^[:space:]]*\)$|\1|p" \
    "$repository_root/compose.yaml")
  pinned_version="$compose_version_prefix$pinned_image"

  if [[ "$pinned_version" != "$latest_version" ]]; then
    printf '%s pin %s is not latest stable %s.\n' \
      "$repository" "$pinned_version" "$latest_version" >&2
    exit 1
  fi

  manifest=$(docker buildx imagetools inspect "$image_repository:$pinned_image")
  if ! grep -Eq 'Platform:[[:space:]]+linux/amd64' <<< "$manifest" || \
    ! grep -Eq 'Platform:[[:space:]]+linux/arm64' <<< "$manifest"; then
    printf '%s:%s must support linux/amd64 and linux/arm64.\n' \
      "$image_repository" "$pinned_image" >&2
    exit 1
  fi
}

validate_component prometheus/prometheus prom/prometheus ""
validate_component prometheus/alertmanager prom/alertmanager ""
validate_component grafana/grafana grafana/grafana v
validate_component prometheus/node_exporter quay.io/prometheus/node-exporter ""
validate_component google/cadvisor ghcr.io/google/cadvisor ""
validate_component prometheus/blackbox_exporter quay.io/prometheus/blackbox-exporter ""

#==============================================================================
# DOCKER PACKAGE VALIDATION
#==============================================================================

latest_package_version() {
  local package_name="$1"
  local package_file="$2"

  awk -v target="$package_name" '
    $0 == "Package: " target { package_found = 1; next }
    package_found && /^Version:/ { print $2; package_found = 0 }
  ' "$package_file" | sort -V | tail -n 1
}

for architecture in amd64 arm64; do
  package_file="$temporary_directory/docker-$architecture-packages"
  curl --fail --silent --show-error \
    "https://download.docker.com/linux/ubuntu/dists/noble/stable/binary-$architecture/Packages.gz" | \
    gzip -dc > "$package_file"

  for package_name in containerd.io docker-buildx-plugin docker-ce docker-compose-plugin; do
    latest_version=$(latest_package_version "$package_name" "$package_file")
    printf '%s=%s\n' "$package_name" "$latest_version" >> \
      "$temporary_directory/latest-$architecture"
  done
done

if ! cmp --silent "$temporary_directory/latest-amd64" "$temporary_directory/latest-arm64"; then
  printf 'Latest Docker package versions differ between AMD64 and ARM64.\n' >&2
  exit 1
fi

pinned_containerd_version=$(sed -n "s/^containerd_version=\"\${CONTAINERD_VERSION:-\(.*\)}\"$/\1/p" \
  "$repository_root/scripts/install-docker.sh")
pinned_docker_buildx_version=$(sed -n "s/^docker_buildx_version=\"\${DOCKER_BUILDX_VERSION:-\(.*\)}\"$/\1/p" \
  "$repository_root/scripts/install-docker.sh")
pinned_docker_compose_version=$(sed -n "s/^docker_compose_version=\"\${DOCKER_COMPOSE_VERSION:-\(.*\)}\"$/\1/p" \
  "$repository_root/scripts/install-docker.sh")
pinned_docker_engine_version=$(sed -n "s/^docker_engine_version=\"\${DOCKER_ENGINE_VERSION:-\(.*\)}\"$/\1/p" \
  "$repository_root/scripts/install-docker.sh")

while IFS='=' read -r package_name latest_version; do
  case "$package_name" in
    containerd.io)
      pinned_version="$pinned_containerd_version"
      ;;
    docker-buildx-plugin)
      pinned_version="$pinned_docker_buildx_version"
      ;;
    docker-ce)
      pinned_version="$pinned_docker_engine_version"
      ;;
    docker-compose-plugin)
      pinned_version="$pinned_docker_compose_version"
      ;;
  esac

  if [[ "$pinned_version" != "$latest_version" ]]; then
    printf '%s pin %s is not latest stable %s.\n' \
      "$package_name" "$pinned_version" "$latest_version" >&2
    exit 1
  fi
done < "$temporary_directory/latest-amd64"

printf 'latest_version_pins=ready\n'
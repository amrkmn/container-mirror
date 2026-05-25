#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE="${SOURCE:-codefloe.com/crow-plugins}"
TARGET="${TARGET:-quay.io/amrkmn/crow}"

IMAGES=(ansible auto-releaser clone docker-buildx renovate sccache)

skopeo_login() {
  local registry="$1" user="$2" pass="$3" required="${4:-false}"
  [[ -z "$user" || -z "$pass" ]] && {
    [[ "$required" == true ]] && { echo "Missing credentials for $registry" >&2; exit 1; }
    return 0
  }
  echo "$pass" | skopeo login -u "$user" --password-stdin "$registry"
}

skopeo_login "${SOURCE%%/*}" "${SOURCE_REGISTRY_USERNAME:-}" "${SOURCE_REGISTRY_PASSWORD:-}"
skopeo_login "${TARGET%%/*}" "${TARGET_REGISTRY_USERNAME:-}" "${TARGET_REGISTRY_PASSWORD:-}" true

for image in "${IMAGES[@]}"; do
  skopeo sync --all --retry-times 5 --src docker --dest docker "$SOURCE/$image" "$TARGET"
done

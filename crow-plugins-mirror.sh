#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE="${SOURCE:-codefloe.com/crow-plugins}"
TARGET="${TARGET:-quay.io/amrkmn/crow}"

IMAGES=(ansible auto-releaser clone docker-buildx renovate sccache)

regctl_login() {
  local registry="$1" user="$2" pass="$3" required="${4:-false}"

  if [[ -z "$user" && -z "$pass" ]]; then
    [[ "$required" == true ]] && { echo "missing credentials for $registry" >&2; exit 1; }
    return 0
  fi

  if [[ -z "$user" || -z "$pass" ]]; then
    echo "incomplete credentials for $registry" >&2
    exit 1
  fi

  printf '%s\n' "$pass" | regctl registry login "$registry" -u "$user" --pass-stdin
  log "logged in to $registry"
}

log() {
  printf '%s\n' "$*"
}

group_start() {
  printf '::group::%s\n' "$*"
}

group_end() {
  printf '::endgroup::\n'
}

retry() {
  local attempts="$1"
  shift

  local attempt
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if "$@"; then
      return 0
    fi

    log "  attempt ${attempt}/${attempts} failed: $*"

    if ((attempt == attempts)); then
      return 1
    fi

    sleep $((attempt * 5))
  done
}

copy_image() {
  local src="$1" dst="$2" output status

  if output="$(regctl -v info image copy "$src" "$dst" 2>&1)"; then
    status=0
  else
    status=$?
  fi

  if ((status != 0)); then
    while IFS= read -r line; do
      printf '    %s\n' "$line" >&2
    done <<<"$output"
    return "$status"
  fi

  printf '  copied to %s\n' "$dst"
}

group_start "authenticate registries"
regctl_login "${SOURCE%%/*}" "${SOURCE_REGISTRY_USERNAME:-}" "${SOURCE_REGISTRY_PASSWORD:-}"
regctl_login "${TARGET%%/*}" "${TARGET_REGISTRY_USERNAME:-}" "${TARGET_REGISTRY_PASSWORD:-}" true
group_end

for image in "${IMAGES[@]}"; do
  group_start "mirror $image"
  log "mirroring $SOURCE/$image -> $TARGET/$image"
  mapfile -t tags < <(regctl tag ls "$SOURCE/$image")
  log "found ${#tags[@]} tags"

  for tag in "${tags[@]}"; do
    log "copying to $image:$tag"
    retry 5 copy_image "$SOURCE/$image:$tag" "$TARGET/$image:$tag"
  done

  log "done $image"
  group_end
done

#!/usr/bin/env bash
# Mirror crow plugin images from SOURCE to TARGET.
#
# Environment:
#   SOURCE/TARGET                 Registry repositories
#   SOURCE_REGISTRY_USERNAME      Optional source registry username
#   SOURCE_REGISTRY_PASSWORD      Optional source registry password
#   TARGET_REGISTRY_USERNAME      Required target registry username
#   TARGET_REGISTRY_PASSWORD      Required target registry password
#   TAG_FILTER                    ERE regex for tags to sync (default: .*)
#   MAX_JOBS                      Parallel image mirrors (default: 4)
#   DRY_RUN                       true = print copies without executing
set -Eeuo pipefail

SOURCE="${SOURCE:-codefloe.com/crow-plugins}"
TARGET="${TARGET:-quay.io/amrkmn/crow}"
TAG_FILTER="${TAG_FILTER:-.*}"
MAX_JOBS="${MAX_JOBS:-4}"
DRY_RUN="${DRY_RUN:-false}"

IMAGES=(ansible auto-releaser clone docker-buildx renovate sccache)

STARTED_AT=$(date +%s)
TMP_DIR=$(mktemp -d)
CURRENT_GROUP=""

log() { printf '%s\n' "$*"; }

emit() {
  local level="$1" prefix="$2" fd="$3"
  shift 3

  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    printf '::%s::%s\n' "$level" "$*"
  else
    printf '%s%s\n' "$prefix" "$*" >&"$fd"
  fi
}

notice() { emit notice "" 1 "$*"; }
warn() { emit warning "warning: " 1 "$*"; }
error() { emit error "error: " 2 "$*"; }

group_start() {
  CURRENT_GROUP="$*"
  [[ -n "${GITHUB_ACTIONS:-}" ]] && printf '::group::%s\n' "$CURRENT_GROUP"
  return 0
}

group_end() {
  [[ -z "$CURRENT_GROUP" ]] && return 0
  [[ -n "${GITHUB_ACTIONS:-}" ]] && printf '::endgroup::\n'
  CURRENT_GROUP=""
}

fmt_elapsed() {
  local seconds="$1"
  ((seconds >= 60)) && printf '%dm %ds' $((seconds / 60)) $((seconds % 60)) || printf '%ds' "$seconds"
}

stat_file() { printf '%s/stats/%s.stat' "$TMP_DIR" "$1"; }
log_file() { printf '%s/logs/%s.log' "$TMP_DIR" "$1"; }

write_stat() {
  local image="$1" tags="$2" copied="$3" current="$4" failed="$5" elapsed="$6"
  printf '%s|%s|%s|%s|%s|%s\n' "$image" "$tags" "$copied" "$current" "$failed" "$elapsed" >"$(stat_file "$image")"
}

total_stat() {
  local field="$1"
  compgen -G "$TMP_DIR/stats/*.stat" >/dev/null || { printf '0\n'; return 0; }
  awk -F'|' -v field="$field" '{ total += $field } END { print total + 0 }' "$TMP_DIR"/stats/*.stat
}

write_summary() {
  [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] && return 0

  local elapsed failed status
  elapsed=$(fmt_elapsed $(($(date +%s) - STARTED_AT)))
  failed=$(total_stat 5)
  status=success
  ((failed > 0)) && status=failed

  {
    printf '## Crow plugin mirror summary\n\n'
    printf '```text\n'
    printf 'status        %s\n' "$status"
    [[ "$DRY_RUN" == "true" ]] && printf 'mode          dry-run (no changes made)\n'
    printf 'duration      %s\n' "$elapsed"
    printf 'images        %d\n' "${#IMAGES[@]}"
    printf 'tags checked  %s\n' "$(total_stat 2)"
    printf 'copied        %s\n' "$(total_stat 3)"
    printf 'current       %s\n' "$(total_stat 4)"
    printf 'failed        %s\n' "$failed"

    if compgen -G "$TMP_DIR/stats/*.stat" >/dev/null; then
      printf '\nimages\n'
      sort "$TMP_DIR"/stats/*.stat | while IFS='|' read -r image tags copied current image_failed image_elapsed; do
        printf '  %-14s tags=%s copied=%s current=%s failed=%s duration=%s\n' \
          "$image" "$tags" "$copied" "$current" "$image_failed" "$image_elapsed"
      done
    fi
    printf '```\n'
  } >>"$GITHUB_STEP_SUMMARY"
}

cleanup() {
  local status=$?
  group_end
  write_summary
  rm -rf "$TMP_DIR"
  exit "$status"
}
trap cleanup EXIT

check_deps() {
  command -v regctl >/dev/null || {
    error "missing required tool: regctl"
    error "install regctl: https://github.com/regclient/regclient/releases"
    exit 1
  }

  [[ "$MAX_JOBS" =~ ^[1-9][0-9]*$ ]] || { error "MAX_JOBS must be a positive integer"; exit 1; }
}

regctl_login() {
  local registry="$1" user="${2:-}" pass="${3:-}" required="${4:-false}"

  if [[ -z "$user" && -z "$pass" ]]; then
    [[ "$required" == true ]] && { error "missing credentials for $registry"; exit 1; }
    log "using anonymous access for $registry"
    return 0
  fi

  [[ -z "$user" || -z "$pass" ]] && { error "incomplete credentials for $registry"; exit 1; }

  printf '%s\n' "$pass" | regctl registry login "$registry" -u "$user" --pass-stdin
  log "logged in to $registry"
}

image_digest() { regctl image digest "$1" 2>/dev/null; }

retry() {
  local attempts="$1" attempt delay rc
  shift

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    "$@" && return 0
    rc=$?
    warn "attempt ${attempt}/${attempts} failed: $*"
    ((attempt == attempts)) && return "$rc"
    delay=$((attempt * 5))
    log "retrying in ${delay}s..."
    sleep "$delay"
  done
}

copy_image() {
  local src="$1" dst="$2" output

  if [[ "$DRY_RUN" == "true" ]]; then
    log "[dry-run] would copy $src -> $dst"
    return 0
  fi

  if output=$(regctl -v info image copy "$src" "$dst" 2>&1); then
    return 0
  fi

  error "copy failed: $src -> $dst"
  while IFS= read -r line; do
    printf '    %s\n' "$line" >&2
  done <<<"$output"
  return 1
}

copy_if_changed() {
  local src="$1" dst="$2" src_digest dst_digest

  src_digest=$(image_digest "$src") || { error "cannot read source digest: $src"; return 2; }
  if dst_digest=$(image_digest "$dst") && [[ "$src_digest" == "$dst_digest" ]]; then
    return 10
  fi

  retry 5 copy_image "$src" "$dst"
}

mirror_image() {
  local image="$1" started_at elapsed tag rc src dst
  local copied=0 current=0 failed=0
  local -a all_tags=() tags=()

  started_at=$(date +%s)

  mapfile -t all_tags < <(regctl tag ls "$SOURCE/$image")
  for tag in "${all_tags[@]}"; do
    [[ "$tag" =~ $TAG_FILTER ]] && tags+=("$tag")
  done

  log "checking ${#tags[@]} tags (${#all_tags[@]} total, $(( ${#all_tags[@]} - ${#tags[@]} )) filtered)"

  for tag in "${tags[@]}"; do
    src="$SOURCE/$image:$tag"
    dst="$TARGET/$image:$tag"

    if copy_if_changed "$src" "$dst"; then
      copied=$((copied + 1))
      log "copied  $image:$tag"
    else
      rc=$?
      if ((rc == 10)); then
        current=$((current + 1))
      else
        failed=$((failed + 1))
      fi
    fi
  done

  elapsed=$(fmt_elapsed $(($(date +%s) - started_at)))
  if ((copied > 0)); then
    log "done $image: copied=$copied current=$current failed=$failed ($elapsed)"
  else
    log "done $image: no changes, current=$current failed=$failed ($elapsed)"
  fi

  write_stat "$image" "${#tags[@]}" "$copied" "$current" "$failed" "$elapsed"
  ((failed == 0))
}

flush_image_log() {
  local image="$1" file
  file=$(log_file "$image")
  [[ -s "$file" ]] || return 0

  group_start "mirror $image"
  cat "$file"
  group_end
}

run_parallel() {
  local running=0 failed=0 image

  for image in "${IMAGES[@]}"; do
    mirror_image "$image" >"$(log_file "$image")" 2>&1 &
    if ((++running >= MAX_JOBS)); then
      wait -n || failed=1
      running=$((running - 1))
    fi
  done

  while ((running > 0)); do
    wait -n || failed=1
    running=$((running - 1))
  done

  for image in "${IMAGES[@]}"; do
    flush_image_log "$image"
  done

  return "$failed"
}

check_deps
mkdir -p "$TMP_DIR/stats" "$TMP_DIR/logs"

[[ "$DRY_RUN" == "true" ]] && warn "DRY_RUN=true - no images will be copied"

group_start "authenticate registries"
regctl_login "${SOURCE%%/*}" "${SOURCE_REGISTRY_USERNAME:-}" "${SOURCE_REGISTRY_PASSWORD:-}"
regctl_login "${TARGET%%/*}" "${TARGET_REGISTRY_USERNAME:-}" "${TARGET_REGISTRY_PASSWORD:-}" true
group_end

if run_parallel; then
  run_status=0
else
  run_status=1
fi

notice "mirror complete: copied=$(total_stat 3) current=$(total_stat 4) failed=$(total_stat 5)"
exit "$run_status"

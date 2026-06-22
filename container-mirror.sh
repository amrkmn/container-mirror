#!/usr/bin/env bash
# Mirror container images from source registries to target registries.
# Groups defined in mirrors.json, or via SOURCE/TARGET/IMAGES env vars.
set -Eeuo pipefail

# ── config ──────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

: "${MIRRORS_FILE:=$SCRIPT_DIR/mirrors.json}"
: "${TAG_FILTER:=.*}"
: "${MAX_JOBS:=4}"
: "${DRY_RUN:=false}"
readonly MIRRORS_FILE TAG_FILTER MAX_JOBS DRY_RUN

readonly STARTED_AT=$(date +%s)
readonly TMP_DIR=$(mktemp -d)
CURRENT_GROUP=""
CREDS_JSON=""
GROUP_COUNT=0
IMAGE_COUNT=0
VERBOSE="${VERBOSE:-false}"

# ── colors ──────────────────────────────────────────────────────────────

if [[ -z "${NO_COLOR:-}" ]]; then
  if [[ -t 1 || -n "${GITHUB_ACTIONS:-}" ]]; then
    C_CYAN=$'\033[36m' C_GREEN=$'\033[32m' C_MAGENTA=$'\033[35m'
    C_RED=$'\033[31m'  C_GRAY=$'\033[90m'  C_RESET=$'\033[0m'
  else
    C_CYAN='' C_GREEN='' C_MAGENTA='' C_RED='' C_GRAY='' C_RESET=''
  fi
else
  C_CYAN='' C_GREEN='' C_MAGENTA='' C_RED='' C_GRAY='' C_RESET=''
fi

# ── helpers ─────────────────────────────────────────────────────────────

log()        { printf '%s\n' "$*"; }
elapsed_str() {
  local s="$1"
  ((s >= 60)) && printf '%dm %ds' $((s / 60)) $((s % 60)) || printf '%ds' "$s"
}

gh_action()  { [[ -n "${GITHUB_ACTIONS:-}" ]]; }

annotation() {
  local level="$1"; shift
  gh_action && printf '::%s::%s\n' "$level" "$*"
  return 0
}

notice()  { annotation notice "$*";  log "$*"; }
warn()    { annotation warning "$*"; log "warning: $*"; }
error()   { annotation error "$*";   log "error: $*" >&2; }

group_start() {
  CURRENT_GROUP="$*"
  gh_action && printf '::group::%s\n' "$*"
}
group_end() {
  [[ -z "$CURRENT_GROUP" ]] && return
  gh_action && printf '::endgroup::\n'
  CURRENT_GROUP=""
}

# Suppress regctl stderr noise (login-user-change WARNs) unless VERBOSE=true.
_regctl_stderr() {
  if [[ "$VERBOSE" == true ]]; then
    regctl "$@"
  else
    regctl "$@" 2>/dev/null
  fi
}

# ── stats & summary ─────────────────────────────────────────────────────

stat_file() { printf '%s/stats/%s.stat' "$TMP_DIR" "$1"; }

write_stat() {
  printf '%s|%s|%s|%s|%s|%s\n' "$@" >"$(stat_file "$1")"
}

stat_sum() {
  local field="$1"
  compgen -G "$TMP_DIR/stats/*.stat" >/dev/null 2>&1 || { printf 0; return; }
  awk -F'|' -v f="$field" '{s+=$f} END{print s+0}' "$TMP_DIR"/stats/*.stat
}

write_summary() {
  [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] && return
  local failed
  failed=$(stat_sum 5)
  {
    printf '## Mirror summary\n\n```text\n'
    printf 'status        %s\n' "$([[ $failed -eq 0 ]] && echo success || echo failed)"
    [[ "$DRY_RUN" == true ]] && printf 'mode          dry-run (no changes made)\n'
    printf 'duration      %s\n' "$(elapsed_str $(($(date +%s) - STARTED_AT)))"
    printf 'groups        %s\n' "$GROUP_COUNT"
    printf 'images        %s\n' "$IMAGE_COUNT"
    printf 'tags checked  %s\n' "$(stat_sum 2)"
    printf 'copied        %s\n' "$(stat_sum 3)"
    printf 'current       %s\n' "$(stat_sum 4)"
    printf 'failed        %s\n' "$failed"

    if compgen -G "$TMP_DIR/stats/*.stat" >/dev/null 2>&1; then
      printf '\nimages\n'
      local prev_group=""
      while IFS='|' read -r key tags copied current failed elapsed; do
        local grp="${key%%/*}" img="${key#*/}"
        if [[ "$grp" != "$prev_group" ]]; then
          printf '  [%s]\n' "$grp"
          prev_group="$grp"
        fi
        printf '    %-14s tags=%s copied=%s current=%s failed=%s duration=%s\n' \
          "$img" "$tags" "$copied" "$current" "$failed" "$elapsed"
      done < <(sort "$TMP_DIR"/stats/*.stat)
    fi
    printf '```\n'
  } >>"$GITHUB_STEP_SUMMARY"
}

cleanup() {
  local rc=$?
  group_end
  write_summary
  rm -rf "$TMP_DIR"
  exit "$rc"
}
trap cleanup EXIT

# ── dependencies ────────────────────────────────────────────────────────

check_deps() {
  command -v regctl >/dev/null || {
    error "regctl required — https://github.com/regclient/regclient/releases"
    exit 1
  }
  [[ "$MAX_JOBS" =~ ^[1-9][0-9]*$ ]] || { error "MAX_JOBS must be positive int"; exit 1; }
}

# ── registry auth ───────────────────────────────────────────────────────

regctl_login() {
  local host="$1" user="${2:-}" pass="${3:-}" required="${4:-false}"

  if [[ -z "$user$pass" ]]; then
    [[ "$required" == true ]] && { error "no credentials for $host"; exit 1; }
    log "using anonymous access for $host"
    return
  fi

  [[ -n "$user" && -n "$pass" ]] || { error "incomplete credentials for $host"; exit 1; }
  _regctl_stderr registry login "$host" -u "$user" --pass-stdin <<<"$pass"
  log "  logged in to $host"
}

# ── image operations ────────────────────────────────────────────────────

image_digest() { regctl image digest "$1" 2>/dev/null; }

retry() {
  local max="$1" i=1
  shift
  for (( ; i <= max; i++)); do
    "$@" && return 0
    if ((i < max)); then
      log "  retry ${i}/${max}: $*"
      sleep "$((i * 5))"
    else
      log "  failed after ${max} attempts: $*"
      return 1
    fi
  done
}

copy_image() {
  if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] would copy $1 -> $2"
    return 0
  fi
  if output=$(regctl image copy "$1" "$2" 2>&1); then
    return 0
  fi
  # ponytail: log to file, no ::error:: annotation spam. Caller aggregates.
  log "  ${C_RED}copy failed:${C_RESET} $1 -> $2"
  while IFS= read -r line; do printf '    %s\n' "$line"; done <<<"$output"
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

# ── mirror single image ─────────────────────────────────────────────────

# ponytail: fetch tags in foreground so "checking" appears instantly.
# Only copy_if_changed loop runs in background.
mirror_image() {
  local image="$1" source="$2" target="$3" group_id="$4" live_fd="$5"
  shift 5
  local -a tags=("$@")
  local copied=0 current=0 failed=0 rc

  local start=$(date +%s)

  # ponytail: tag fetch + "checking" log goes to live_fd (parent terminal).
  # Copy work + "done" go to the log file (fd 1, buffered).
  local -a all_tags=()
  mapfile -t all_tags < <(regctl tag ls "$source/$image" 2>/dev/null)
  local filtered=0
  for tag in "${all_tags[@]}"; do
    [[ "$tag" =~ $TAG_FILTER ]] && tags+=("$tag")
  done
  filtered=$(( ${#all_tags[@]} - ${#tags[@]} ))
  printf "  ${C_GREEN}checking${C_RESET} %s: %s tags (%d total, %d filtered)\n" \
    "$image" "${#tags[@]}" "${#all_tags[@]}" "$filtered" >&"$live_fd"

  for tag in "${tags[@]}"; do
    if copy_if_changed "$source/$image:$tag" "$target/$image:$tag"; then
      ((copied++))
      printf "  ${C_GREEN}copied${C_RESET}  $image:$tag\n" >&"$live_fd"
      log "  ${C_GREEN}copied${C_RESET}  $image:$tag"
    else
      rc=$?
      if ((rc == 10)); then
        ((current++))
      else
        ((failed++))
      fi
    fi
  done

  local elapsed
  elapsed=$(elapsed_str $(($(date +%s) - start)))
  if ((copied > 0)); then
    log "  ${C_MAGENTA}done${C_RESET} $image: copied=$copied current=$current failed=$failed ${C_GRAY}(${elapsed})${C_RESET}"
  else
    log "  ${C_MAGENTA}done${C_RESET} $image: no changes, current=$current failed=$failed ${C_GRAY}(${elapsed})${C_RESET}"
  fi

  write_stat "$group_id/$image" "${#tags[@]}" "$copied" "$current" "$failed" "$elapsed"
  return $((failed == 0 ? 0 : 1))
}

# ── parallel runner ─────────────────────────────────────────────────────

run_parallel() {
  local group_id="$1" source="$2" target="$3"
  shift 3
  local -a images=("$@")
  local running=0 failed=0 logdir="$TMP_DIR/logs/$group_id" statsdir="$TMP_DIR/stats/$group_id"
  local -A flushed=()

  mkdir -p "$logdir" "$statsdir"

  # ponytail: each background job gets a dedicated fd to the terminal
  # for the "checking" line. Copy output goes to a log file, flushed when
  # "done" appears.
  _flush_done() {
    local img
    for img in "${images[@]}"; do
      [[ -n "${flushed[$img]:-}" ]] && continue
      [[ -s "$logdir/$img.log" ]] || continue
      tail -1 "$logdir/$img.log" 2>/dev/null | sed $'s/\033\\[[0-9;]*m//g' | grep -q '^  done' || continue
      { cat "$logdir/$img.log"; }
      flushed[$img]=1
    done
  }

  for img in "${images[@]}"; do
    exec {live_fd}>&1
    mirror_image "$img" "$source" "$target" "$group_id" "$live_fd" >"$logdir/$img.log" 2>&1 &
    exec {live_fd}>&-
    if ((++running >= MAX_JOBS)); then
      wait -n || failed=1
      ((running--))
      _flush_done
    fi
  done

  while ((running > 0)); do
    wait -n || failed=1
    ((running--))
    _flush_done
  done

  _flush_done

  return "$failed"
}

# ── credentials ─────────────────────────────────────────────────────────

cred_field() {
  local host="$1" direction="$2" field="$3"
  command -v jq >/dev/null 2>&1 || return
  jq -r --arg h "$host" --arg f "$field" ".\"$direction\"[\$h][\$f] // empty" <<<"$CREDS_JSON"
}

load_creds() {
  local file="${REGISTRY_CREDENTIALS_FILE:-${SCRIPT_DIR}/.creds.json}"
  [[ -f "$file" ]] && CREDS_JSON=$(<"$file")
  [[ -n "${REGISTRY_CREDENTIALS:-}" ]] && CREDS_JSON="$REGISTRY_CREDENTIALS"
  [[ -z "$CREDS_JSON" ]] && return

  command -v jq >/dev/null || { warn "jq missing, creds skipped"; CREDS_JSON=""; return; }
  jq -e '.source and .destination' <<<"$CREDS_JSON" >/dev/null 2>&1 || {
    error "creds must have 'source' and 'destination' keys"
    exit 1
  }
}

# ── mirror group ────────────────────────────────────────────────────────

mirror_group() {
  local source="$1" target="$2" group_id="$3"
  shift 3
  local -a images=("$@")

  local src_host="${source%%/*}" tgt_host="${target%%/*}"

  local src_user="${SOURCE_REGISTRY_USERNAME:-}"
  local src_pass="${SOURCE_REGISTRY_PASSWORD:-}"
  local tgt_user="${TARGET_REGISTRY_USERNAME:-}"
  local tgt_pass="${TARGET_REGISTRY_PASSWORD:-}"

  if [[ -n "$CREDS_JSON" ]]; then
    [[ -z "$src_user" ]] && src_user=$(cred_field "$src_host" source user)
    [[ -z "$src_pass" ]] && src_pass=$(cred_field "$src_host" source password)
    [[ -z "$tgt_user" ]] && tgt_user=$(cred_field "$tgt_host" destination user)
    [[ -z "$tgt_pass" ]] && tgt_pass=$(cred_field "$tgt_host" destination password)
  fi

  notice "${C_CYAN}[$group_id]${C_RESET} $source -> $target"

  regctl_login "$src_host" "$src_user" "$src_pass"
  regctl_login "$tgt_host" "$tgt_user" "$tgt_pass" true

  run_parallel "$group_id" "$source" "$target" "${images[@]}"
}

# ── load mirror groups ──────────────────────────────────────────────────

load_mirrors() {
  if [[ -n "${SOURCE:-}${TARGET:-}${IMAGES:-}" ]]; then
    IFS=' ' read -ra imgs <<<"${IMAGES:-}"
    GROUP_COUNT=1
    IMAGE_COUNT=${#imgs[@]}
    mirror_group "$SOURCE" "$TARGET" "${TARGET##*/}" "${imgs[@]}"
    return $?
  fi

  command -v jq >/dev/null || { error "jq required to parse $MIRRORS_FILE"; exit 1; }
  [[ -f "$MIRRORS_FILE" ]] || {
    error "MIRRORS_FILE not found: $MIRRORS_FILE"
    error "Set SOURCE/TARGET/IMAGES env vars for single-group mode"
    exit 1
  }

  GROUP_COUNT=$(jq length "$MIRRORS_FILE")
  IMAGE_COUNT=$(jq '[.[].images[]] | length' "$MIRRORS_FILE")
  local rc=0

  while IFS= read -r row; do
    local source target group_id
    source=$(jq -r .source <<<"$row")
    target=$(jq -r .target <<<"$row")
    group_id="${target##*/}"
    mapfile -t imgs < <(jq -r '.images[]' <<<"$row")
    mirror_group "$source" "$target" "$group_id" "${imgs[@]}" || rc=1
  done < <(jq -c '.[]' "$MIRRORS_FILE")
  return "$rc"
}

# ── main ────────────────────────────────────────────────────────────────

check_deps
mkdir -p "$TMP_DIR"/{stats,logs}
[[ "$DRY_RUN" == true ]] && warn "DRY_RUN=true — no images will be copied"

load_creds
load_mirrors
run_status=$?

notice ""
notice "mirror complete: copied=$(stat_sum 3) current=$(stat_sum 4) failed=$(stat_sum 5)"
exit "$run_status"

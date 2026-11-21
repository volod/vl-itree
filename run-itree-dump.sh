#!/usr/bin/env bash

set -euo pipefail

# InvenTree backup utility for the vl-itree stack.
#
# Writes inventree-dump/<timestamp>/ (directory 0700, files 0600):
#   db.dump        PostgreSQL custom-format dump (pg_restore)
#   keys.tar.gz    SECRET: secret_key.txt, config.yaml, oidc.pem, plugins.txt,
#                  Caddy state (internal CA). Without secret_key.txt every API
#                  token is invalid after a restore (InvenTree >= 1.6.0).
#   assets.tar.gz  media, static, plugins and the legacy config/ directory
#   metadata.txt   context (versions, mode, file list); no secrets
#   SHA256SUMS     checksums of the files above
#
# Modes:
#   default    stop server and worker; database and proxy stay up
#   --offline  stop every service except the database (which pg_dump needs)
#   --no-restart  leave the stopped services stopped (use before an upgrade)
#
# The database is read through the container's local socket as the database
# owner, so no password is passed on any command line or written anywhere.
# Data-directory files are read inside the database container because the
# InvenTree container creates them as root.
#
# File names, lists and container names: lib/itree-config.sh
# Procedure and restore: docs/backup-restore.md

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
project_root="$script_dir"
# shellcheck source=lib/itree-common.sh
. "$project_root/lib/itree-common.sh"

timestamp="$(date +"$ITREE_DUMP_TIMESTAMP_FORMAT")"
dump_dir="$ITREE_DUMP_ROOT/$timestamp"

MODE="quiesced"
NO_RESTART=false
stopped_services=()
started_db=false

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--offline] [--no-restart]

Create a backup in $(basename "$ITREE_DUMP_ROOT")/<timestamp>/ containing:
  - $ITREE_DUMP_DB_FILE        PostgreSQL database dump (custom format)
  - $ITREE_DUMP_KEYS_FILE    $ITREE_BACKUP_REQUIRED_KEYS $ITREE_BACKUP_OPTIONAL_KEYS
  - $ITREE_DUMP_ASSETS_FILE  $ITREE_BACKUP_ASSET_DIRS
  - $ITREE_DUMP_METADATA_FILE and $ITREE_DUMP_CHECKSUM_FILE

Options:
  --offline     Stop every service except the database during the backup
                (default stops only server and worker)
  --no-restart  Do not restart the stopped services afterwards
USAGE
}

restore_services() {
  local rc=$?
  set +e
  if [ "$NO_RESTART" = false ] && [ "${#stopped_services[@]}" -gt 0 ]; then
    log "Starting services again: ${stopped_services[*]}"
    itree_compose start "${stopped_services[@]}" >/dev/null || err "WARNING: could not restart ${stopped_services[*]}; run: bash run-itree.sh up"
  elif [ "${#stopped_services[@]}" -gt 0 ]; then
    log "Leaving stopped (--no-restart): ${stopped_services[*]}"
  fi
  if [ "$started_db" = true ]; then
    log "Stopping the database container again"
    itree_compose stop "$ITREE_CT_DB" >/dev/null || true
  fi
  if [ "$rc" -ne 0 ]; then
    if [ -d "$dump_dir" ] && mv "$dump_dir" "$dump_dir.incomplete" 2>/dev/null; then
      err "Backup FAILED (exit $rc). Partial files moved to $dump_dir.incomplete; do not use them for a restore."
    else
      err "Backup FAILED (exit $rc). Do not use $dump_dir for a restore."
    fi
  fi
  exit "$rc"
}

stop_services() {
  local svc candidates
  case "$MODE" in
    offline) candidates="$ITREE_BACKUP_STOP_OFFLINE" ;;
    *) candidates="$ITREE_BACKUP_STOP_QUIESCED" ;;
  esac
  for svc in $candidates; do
    if container_running "$svc"; then
      stopped_services+=("$svc")
    fi
  done
  if [ "${#stopped_services[@]}" -gt 0 ]; then
    log "Stopping for $MODE backup: ${stopped_services[*]}"
    itree_compose stop "${stopped_services[@]}" >/dev/null
  fi
}

ensure_db_running() {
  if container_running "$ITREE_CT_DB"; then
    return 0
  fi
  log "Starting the database container for pg_dump"
  started_db=true
  itree_compose up -d --no-deps --wait "$ITREE_CT_DB" >/dev/null
}

dump_database() {
  local db_file="$dump_dir/$ITREE_DUMP_DB_FILE"
  log "Dumping database to $db_file"
  docker exec "$ITREE_CT_DB" pg_dump -U "$(cfg_get INVENTREE_DB_USER)" -d "$(cfg_get INVENTREE_DB_NAME)" -F c >"$db_file"
  if [ ! -s "$db_file" ]; then
    err "ERROR: database dump is empty"
    return 1
  fi
}

dump_keys() {
  local keys_file="$dump_dir/$ITREE_DUMP_KEYS_FILE"
  log "Archiving secret key and configuration files to $keys_file"
  # Fixed script; the file lists from lib/itree-config.sh arrive as $1 and $2
  # (constant names, never secrets) and are not spliced into the script text.
  # shellcheck disable=SC2016
  docker exec -w "$ITREE_DB_DATA_DIR" "$ITREE_CT_DB" sh -c '
    set -e
    required="$1"
    optional="$2"
    for f in $required; do
      if [ ! -f "$f" ]; then
        echo "ERROR: required file $f is missing from the data directory" >&2
        exit 3
      fi
    done
    set -- $required
    for f in $optional; do
      if [ -e "$f" ]; then set -- "$@" "$f"; fi
    done
    exec tar -czf - "$@"
  ' sh "$ITREE_BACKUP_REQUIRED_KEYS" "$ITREE_BACKUP_OPTIONAL_KEYS" >"$keys_file"
}

dump_assets() {
  local assets_file="$dump_dir/$ITREE_DUMP_ASSETS_FILE"
  log "Archiving assets to $assets_file"
  # shellcheck disable=SC2016
  docker exec -w "$ITREE_DB_DATA_DIR" "$ITREE_CT_DB" sh -c '
    set -e
    dirs="$1"
    set --
    for f in $dirs; do
      if [ -e "$f" ]; then set -- "$@" "$f"; fi
    done
    if [ "$#" -eq 0 ]; then
      echo "ERROR: no asset directories found" >&2
      exit 3
    fi
    exec tar -czf - "$@"
  ' sh "$ITREE_BACKUP_ASSET_DIRS" >"$assets_file"
}

write_metadata() {
  local meta="$dump_dir/$ITREE_DUMP_METADATA_FILE" server_image="" server_version="" pg_version="" repo tag digest
  if container_exists "$ITREE_CT_SERVER"; then
    server_image="$(docker inspect -f '{{.Config.Image}}' "$ITREE_CT_SERVER" 2>/dev/null || true)"
    server_version="$(docker image inspect -f "{{index .Config.Labels \"$ITREE_IMAGE_VERSION_LABEL\"}}" \
      "$(docker inspect -f '{{.Image}}' "$ITREE_CT_SERVER")" 2>/dev/null || true)"
  fi
  pg_version="$(docker exec "$ITREE_CT_DB" postgres --version 2>/dev/null || true)"
  {
    printf 'timestamp=%s\n' "$timestamp"
    printf 'mode=%s\n' "$MODE"
    printf 'project_root=%s\n' "$project_root"
    printf 'volume_root=%s\n' "$ITREE_VOLUME_ROOT"
    printf 'inventree_container_image=%s\n' "${server_image:-unknown}"
    printf 'inventree_container_version=%s\n' "${server_version:-unknown}"
    printf 'postgres_server=%s\n' "${pg_version:-unknown}"
    while read -r repo tag digest; do
      printf 'pinned_image=%s:%s@%s\n' "$repo" "$tag" "$digest"
    done <<EOF
$(itree_images)
EOF
    printf 'db_name=%s\n' "$(cfg_get INVENTREE_DB_NAME)"
    printf 'db_user=%s\n' "$(cfg_get INVENTREE_DB_USER)"
    printf 'keys_tar_contents=%s\n' "$(tar -tzf "$dump_dir/$ITREE_DUMP_KEYS_FILE" | awk '!/^caddy\/data\/./' | tr '\n' ' ')"
    printf 'note=%s holds the Django secret key and private keys; store this backup like a password\n' "$ITREE_DUMP_KEYS_FILE"
  } >"$meta"
}

write_checksums() {
  (cd "$dump_dir" && sha256_file "$ITREE_DUMP_DB_FILE" "$ITREE_DUMP_KEYS_FILE" "$ITREE_DUMP_ASSETS_FILE" \
    "$ITREE_DUMP_METADATA_FILE" >"$ITREE_DUMP_CHECKSUM_FILE")
}

main() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --offline) MODE="offline" ;;
      --no-restart) NO_RESTART=true ;;
      -h | --help) usage; exit 0 ;;
      *) err "Unknown option: $arg"; usage 1>&2; exit 2 ;;
    esac
  done

  log "Project root: $project_root"
  require_tools
  # Lenient: the backup must work even before the password is rotated. It
  # never starts the application, and it reads the database without a password.
  itree_render lenient || exit 1
  if ! db_initialized; then
    err "ERROR: no PostgreSQL data directory at $ITREE_PGDATA_DIR; nothing to back up"
    exit 1
  fi

  umask 077
  mkdir -p "$ITREE_DUMP_ROOT"
  chmod 700 "$ITREE_DUMP_ROOT"
  mkdir "$dump_dir"

  trap restore_services EXIT
  stop_services
  ensure_db_running
  dump_database
  dump_keys
  dump_assets
  write_metadata
  write_checksums

  log "Backup completed: $dump_dir"
  log "Files: $ITREE_DUMP_DB_FILE $ITREE_DUMP_KEYS_FILE $ITREE_DUMP_ASSETS_FILE $ITREE_DUMP_METADATA_FILE $ITREE_DUMP_CHECKSUM_FILE"
  log "$ITREE_DUMP_KEYS_FILE contains secret material; copy the backup to offline storage and protect it."
}

main "$@"

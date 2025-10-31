#!/usr/bin/env bash

set -euo pipefail

# InvenTree backup utility
# - Creates a consistent dump of the PostgreSQL database and application assets
# - Default mode: quiesced backup (stops app containers, keeps DB up)
# - Optional offline mode: stop entire stack during dump

MIN_COMPOSE_VERSION="2.0.0"

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
project_root="$script_dir"
compose_file="$project_root/docker/docker-compose.yml"
env_file="$project_root/.env"

# Match run-itree.sh volume layout
volume_root="$project_root/inventree-volume"

dump_root="$project_root/inventree-dump"
timestamp="$(date +%Y%m%d-%H%M%S)"
dump_dir="$dump_root/$timestamp"

log() {
  printf '%s\n' "$*"
}

err() {
  printf '%s\n' "$*" 1>&2
}

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--offline]

Create a backup containing:
  - PostgreSQL database dump (custom format)
  - Application assets from inventree-volume (media, static, config)

Modes:
  --offline   Stop entire stack during backup (max consistency, more downtime)
              Default behavior stops only app containers (server, worker)
USAGE
}

version_ge() {
  [ "$(printf '%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

require_tools() {
  if ! command -v docker >/dev/null 2>&1; then
    err "Docker is not installed or not in PATH"
    exit 1
  fi
  if docker compose version >/dev/null 2>&1; then
    compose_cmd=(docker compose)
    raw_version="$(docker compose version 2>/dev/null | tr -d '\r')"
    version_number="$(printf '%s' "$raw_version" | sed -nE 's/.*v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')"
    if [ -z "$version_number" ]; then
      err "Unable to parse Docker Compose version"
      exit 1
    fi
    if ! version_ge "$version_number" "$MIN_COMPOSE_VERSION"; then
      err "Docker Compose v$MIN_COMPOSE_VERSION or newer required"
      exit 1
    fi
  else
    err "Docker Compose v2 (docker compose) is required"
    exit 1
  fi
}

require_compose_stack() {
  if [ ! -f "$compose_file" ]; then
    err "docker-compose.yml not found at $compose_file"
    exit 1
  fi
  if [ ! -f "$env_file" ]; then
    err ".env not found at $env_file. Start the stack once to generate it via run-itree.sh"
    exit 1
  fi
}

parse_env() {
  # shellcheck disable=SC1090
  set -a
  . "$env_file"
  set +a
  INVENTREE_DB_HOST="${INVENTREE_DB_HOST:-inventree-db}"
  INVENTREE_DB_PORT="${INVENTREE_DB_PORT:-5432}"
  INVENTREE_DB_NAME="${INVENTREE_DB_NAME:-inventree}"
  INVENTREE_DB_USER="${INVENTREE_DB_USER:-inventree}"
  INVENTREE_DB_PASSWORD="${INVENTREE_DB_PASSWORD:-inventree}"
}

ensure_dirs() {
  mkdir -p "$dump_dir"
}

stop_app_only() {
  "${compose_cmd[@]}" --env-file "$env_file" -f "$compose_file" stop inventree-server inventree-worker >/dev/null
}

start_app_only() {
  "${compose_cmd[@]}" --env-file "$env_file" -f "$compose_file" start inventree-server inventree-worker >/dev/null
}

stop_all() {
  "${compose_cmd[@]}" --env-file "$env_file" -f "$compose_file" down --remove-orphans
}

start_all() {
  "${compose_cmd[@]}" --env-file "$env_file" -f "$compose_file" up -d
}

dump_database() {
  local db_file="$dump_dir/db.dump"
  # Use the running database container for a consistent pg_dump
  # - Custom format allows parallel restore and is a best practice for backups
  log "Dumping database to $db_file"
  docker exec -e PGPASSWORD="$INVENTREE_DB_PASSWORD" inventree-db \
    pg_dump -h "$INVENTREE_DB_HOST" -p "$INVENTREE_DB_PORT" -U "$INVENTREE_DB_USER" \
    -d "$INVENTREE_DB_NAME" -F c -v -f /tmp/inventree-db.dump >/dev/null
  docker cp inventree-db:/tmp/inventree-db.dump "$db_file"
  docker exec inventree-db rm -f /tmp/inventree-db.dump >/dev/null 2>&1 || true
}

dump_assets() {
  local assets_file="$dump_dir/assets.tar.gz"
  log "Archiving assets to $assets_file"
  # Include media, static, and config. Skip logs to reduce size.
  tar -C "$volume_root" -czf "$assets_file" \
    --warning=no-file-changed \
    --ignore-failed-read \
    media static config
}

write_metadata() {
  local meta="$dump_dir/metadata.txt"
  {
    printf 'project_root=%s\n' "$project_root"
    printf 'volume_root=%s\n' "$volume_root"
    printf 'timestamp=%s\n' "$timestamp"
    printf 'mode=%s\n' "$MODE"
    printf 'db_host=%s\n' "$INVENTREE_DB_HOST"
    printf 'db_port=%s\n' "$INVENTREE_DB_PORT"
    printf 'db_name=%s\n' "$INVENTREE_DB_NAME"
    printf 'db_user=%s\n' "$INVENTREE_DB_USER"
  } > "$meta"
}

MODE="quiesced"
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
if [ "${1:-}" = "--offline" ]; then
  MODE="offline"
fi

main() {
  log "Project root: $project_root"
  require_tools
  require_compose_stack
  parse_env
  ensure_dirs

  case "$MODE" in
    offline)
      log "Stopping entire stack for offline backup"
      stop_all
      dump_database
      dump_assets
      write_metadata
      log "Restarting stack"
      start_all
      ;;
    quiesced|*)
      log "Stopping app containers for quiesced backup"
      stop_app_only
      dump_database
      dump_assets
      write_metadata
      log "Starting app containers"
      start_app_only
      ;;
  esac

  log "Backup completed: $dump_dir"
  log "Files: $(basename "$dump_dir")/db.dump, $(basename "$dump_dir")/assets.tar.gz, metadata.txt"
}

main "$@"



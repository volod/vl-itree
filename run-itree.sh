#!/usr/bin/env bash

set -euo pipefail

# Portable launcher for InvenTree using docker compose
# - Detects absolute project path (USB mount agnostic)
# - Verifies Docker and Docker Compose v2
# - Provisions required host directories under a single project volume root
# - Writes/updates .env from embedded template with path substitution
# - Optionally preloads docker images from local cache on USB and saves pulled images back
# - Runs docker compose

# Google Python style is not applicable; we follow shell best practices

MIN_COMPOSE_VERSION="2.0.0"

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
project_root="$script_dir"
compose_file="$project_root/docker/docker-compose.yml"
env_file="$project_root/.env"
contrib_caddyfile="$project_root/InvenTree/contrib/container/Caddyfile"

# Single base directory for all runtime artifacts
volume_root="$project_root/inventree-volume"
# Directory to store/load docker image tarballs
images_cache_dir="$project_root/docker-images"
# Target path for active Caddyfile in the data volume
volume_caddyfile="$volume_root/config/Caddyfile"

# Default contents for .env; the launcher substitutes INVENTREE_EXT_VOLUME at runtime
readonly ENV_TEMPLATE_DEFAULT='
# Template for InvenTree docker-compose environment
# This file is used by run-itree.sh to generate a runtime .env
# The script will replace the placeholder for INVENTREE_EXT_VOLUME.

# InvenTree image tag
INVENTREE_TAG=stable

# Ports the Caddy proxy exposes on the host
INVENTREE_HTTP_PORT=8080
INVENTREE_HTTPS_PORT=8443

# Single host directory used by all services for persistent data, static/media, logs, etc.
# The launcher will substitute this placeholder with the absolute path on this machine.
INVENTREE_EXT_VOLUME=__INVENTREE_EXT_VOLUME__

# Redis cache
INVENTREE_CACHE_PORT=6379
INVENTREE_CACHE_ENABLED=True
INVENTREE_CACHE_HOST=inventree-cache

# InvenTree application settings (minimal baseline)
INVENTREE_SITE_URL=http://localhost
INVENTREE_DEBUG=False
INVENTREE_LOG_LEVEL=INFO
INVENTREE_DB_LOGGING=False
INVENTREE_PLUGINS_ENABLED=True
INVENTREE_AUTO_UPDATE=True

# Database configuration (must match the database container settings)
INVENTREE_DB_ENGINE=postgresql
INVENTREE_DB_NAME=inventree
INVENTREE_DB_HOST=inventree-db
INVENTREE_DB_PORT=5432
INVENTREE_DB_USER=inventree
INVENTREE_DB_PASSWORD=inventree

# Caddyfile optional envs
# INVENTREE_SERVER=http://inventree-server:8000
# INVENTREE_SITE_URL=:80, :443
'

log() {
  printf '%s\n' "$*"
}

err() {
  printf '%s\n' "$*" 1>&2
}

usage() {
  cat <<USAGE
Usage: $(basename "$0") [command]

Commands:
  up            Start or update the stack (default)
  start         Alias for up
  run           Alias for up
  down          Stop and remove the stack (aliases: stop, shutdown); also removes generated .env
  help          Show this help
USAGE
}

version_ge() {
  # Compare two semantic versions (returns 0 if $1 >= $2)
  # Usage: version_ge "2.27.0" "2.5.0"
  [ "$(printf '%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

require_tools() {
  if ! command -v docker >/dev/null 2>&1; then
    err "Docker is not installed or not in PATH"
    exit 1
  fi

  # Prefer docker compose v2
  if docker compose version >/dev/null 2>&1; then
    compose_cmd=(docker compose)
    # Extract version like: Docker Compose version v2.27.0
    raw_version="$(docker compose version 2>/dev/null | tr -d '\r')"
    version_number="$(printf '%s' "$raw_version" | sed -nE 's/.*v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')"
    if [ -z "$version_number" ]; then
      err "Unable to parse Docker Compose version from: $raw_version"
      exit 1
    fi
    if ! version_ge "$version_number" "$MIN_COMPOSE_VERSION"; then
      err "Docker Compose v$MIN_COMPOSE_VERSION or newer required, found v$version_number"
      exit 1
    fi
  else
    err "Docker Compose v2 (docker compose) is required. Please install or upgrade Docker Desktop/CLI."
    exit 1
  fi
}

provision_dirs() {
  # Create a clear structure under the single base volume
  mkdir -p "$volume_root"
  mkdir -p "$volume_root/static"
  mkdir -p "$volume_root/media"
  mkdir -p "$volume_root/log"
  mkdir -p "$volume_root/config"
  mkdir -p "$volume_root/data"
  # PostgreSQL PGDATA will live under this mount as "pgdb" per compose env
  mkdir -p "$volume_root/pgdb"
  # Ensure images cache directory exists
  mkdir -p "$images_cache_dir"
}

ensure_caddyfile() {
  # Ensure an active Caddyfile exists under the data volume for the proxy to mount
  if [ -f "$volume_caddyfile" ]; then
    return 0
  fi
  mkdir -p "$(dirname "$volume_caddyfile")"
  if [ -f "$contrib_caddyfile" ]; then
    cp "$contrib_caddyfile" "$volume_caddyfile"
    log "Installed Caddyfile to $volume_caddyfile"
  else
    err "Contrib Caddyfile not found at $contrib_caddyfile"
    exit 1
  fi
}

write_env() {
  # Write the embedded template into the runtime .env
  printf '%s' "$ENV_TEMPLATE_DEFAULT" > "$env_file"
  # Substitute placeholder with absolute path
  sed -i "s#__INVENTREE_EXT_VOLUME__#${volume_root//#/\\#}#g" "$env_file"
}

image_sanitize_filename() {
  # Replace '/', ':' with '_' for portable filenames
  printf '%s' "$1" | sed 's#[/:]#_#g'
}

image_present() {
  docker image inspect "$1" >/dev/null 2>&1
}

ensure_image() {
  local image="$1"
  local short="$(image_sanitize_filename "$image")"
  local tar_path="$images_cache_dir/${short}.tar"

  if image_present "$image"; then
    return 0
  fi

  if [ -f "$tar_path" ]; then
    log "Loading cached image: $image from $(basename "$tar_path")"
    if docker load -i "$tar_path" >/dev/null 2>&1; then
      return 0
    else
      err "Failed to load $tar_path; will attempt to pull"
    fi
  fi

  log "Pulling image: $image"
  docker pull "$image"
  # Save for reuse
  log "Saving image to cache: $(basename "$tar_path")"
  docker save -o "$tar_path" "$image" || err "Warning: failed to save $image to cache"
}

preload_images() {
  # Determine images required by the stack
  # Note: For simplicity we cover explicit images used in compose
  # InvenTree app and worker tag from .env
  local inventree_tag
  inventree_tag="$(grep -E '^INVENTREE_TAG=' "$env_file" | cut -d'=' -f2 | tr -d '\r')"
  inventree_tag=${inventree_tag:-stable}

  ensure_image "inventree/inventree:${inventree_tag}"
  ensure_image "postgres:17"
  ensure_image "redis:7-alpine"
  ensure_image "caddy:alpine"
}

run_compose() {
  if [ ! -f "$compose_file" ]; then
    err "docker-compose.yml not found at $compose_file"
    exit 1
  fi
  log "Starting InvenTree stack from $project_root"
  (cd "$project_root" && "${compose_cmd[@]}" --env-file "$env_file" -f "$compose_file" up -d)
}

shutdown_stack() {
  if [ ! -f "$compose_file" ]; then
    err "docker-compose.yml not found at $compose_file"
    exit 1
  fi
  log "Stopping InvenTree stack from $project_root"
  (cd "$project_root" && "${compose_cmd[@]}" --env-file "$env_file" -f "$compose_file" down --remove-orphans)
  # Remove generated .env to avoid stale absolute paths on next boot
  if [ -f "$env_file" ]; then
    rm -f "$env_file"
    log "Removed generated .env"
  fi
}

main() {
  cmd="${1:-up}"

  case "$cmd" in
    help|-h|--help)
      usage
      exit 0
      ;;
    down|stop|shutdown)
      log "Project root: $project_root"
      require_tools
      shutdown_stack
      log "InvenTree stack stopped."
      exit 0
      ;;
    up|start|run|*)
      log "Project root: $project_root"
      require_tools
      provision_dirs
      write_env
      ensure_caddyfile
      preload_images
      run_compose
      http_port="$(grep -E '^INVENTREE_HTTP_PORT=' "$env_file" | cut -d'=' -f2 | tr -d '\r')"
      http_port=${http_port:-8080}
      log "InvenTree is starting. HTTP: http://localhost:${http_port}"
      ;;
  esac
}

main "$@"



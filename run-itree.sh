#!/usr/bin/env bash

set -euo pipefail

# Launcher for the vl-itree InvenTree stack (docker compose).
# - Detects the absolute project path (USB mount agnostic)
# - Builds the runtime .env from docker/env.template, .env.local, the
#   environment (credentials only) and docker/versions.env
# - Refuses unsafe configurations before any container is started
# - Optionally preloads pinned images from a local tarball cache
# - Runs docker compose
#
# Constants (paths, container names, limits): lib/itree-config.sh
# Documentation: README.md and docs/ (configuration, TLS, backup, upgrade).

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
project_root="$script_dir"
# shellcheck source=lib/itree-common.sh
. "$project_root/lib/itree-common.sh"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [command] [--dev]

Commands:
  up [--dev]           Validate the configuration and start or update the stack
                       (default; aliases: start, run)
  check [--dev]        Validate the configuration and run "docker compose config"
                       without starting anything
  down                 Stop and remove the containers (aliases: stop, shutdown);
                       removes the generated .env, never .env.local
  rotate-db-password   Set a new random PostgreSQL password with ALTER ROLE,
                       save it to .env.local and restart server and worker
  export-ca [FILE]     Copy the internal CA root certificate (TLS mode
                       "internal") to FILE (default: ./$(basename "$ITREE_CA_EXPORT_FILE"))
  version              Show pinned image versions and the deployed version
  help                 Show this help

Options:
  --dev   Development start: skips the password checks, forces the bind
          address to $ITREE_LOOPBACK_ADDR and, if needed, the site URL to
          http://localhost:<INVENTREE_HTTP_PORT>. Never use for a working
          instance.
USAGE
}

provision_dirs() {
  local dir
  for dir in $ITREE_VOLUME_DIRS; do
    mkdir -p "$ITREE_VOLUME_ROOT/$dir"
  done
  mkdir -p "$ITREE_IMAGES_CACHE_DIR"
}

ensure_image() {
  local repo="$1" tag="$2" digest="$3"
  local ref="$repo:$tag@$digest"
  local short tar_path
  # The file name carries the tag and a digest prefix, so a new pin never
  # reuses an old tarball.
  short="$(printf '%.12s' "${digest#sha256:}")"
  tar_path="$ITREE_IMAGES_CACHE_DIR/$(printf '%s' "$repo" | tr '/' '_')_${tag}_${short}.tar"

  if docker image inspect "$ref" >/dev/null 2>&1; then
    return 0
  fi

  if [ -f "$tar_path" ]; then
    log "Loading cached image $repo:$tag from $(basename "$tar_path")"
    if docker load -i "$tar_path" >/dev/null 2>&1 && docker image inspect "$ref" >/dev/null 2>&1; then
      return 0
    fi
    err "Cached tarball for $repo:$tag cannot be matched to the pinned digest in this image store; pulling instead"
  fi

  log "Pulling image $ref"
  docker pull "$ref"
  docker tag "$ref" "$repo:$tag"
  log "Saving image to cache: $(basename "$tar_path")"
  if docker save -o "$tar_path.partial" "$repo:$tag"; then
    mv -f "$tar_path.partial" "$tar_path"
  else
    rm -f "$tar_path.partial"
    err "Warning: failed to save $repo:$tag to cache"
  fi
}

preload_images() {
  local repo tag digest
  while read -r repo tag digest; do
    ensure_image "$repo" "$tag" "$digest"
  done <<EOF
$(itree_images)
EOF
}

print_summary() {
  local bind https_port http_port
  bind="$(cfg_get INVENTREE_BIND_ADDR)"
  https_port="$(cfg_get INVENTREE_HTTPS_PORT)"
  http_port="$(cfg_get INVENTREE_HTTP_PORT)"
  log "Site URL:    $(cfg_get INVENTREE_SITE_URL)"
  log "TLS mode:    $(cfg_get INVENTREE_PROXY_TLS)"
  log "HTTPS bind:  $bind:$https_port"
  if [ "$(cfg_get INVENTREE_PROXY_TLS)" = none ]; then
    log "HTTP bind:   $ITREE_LOOPBACK_ADDR:$http_port (serves the site, loopback only)"
  else
    log "HTTP bind:   $ITREE_LOOPBACK_ADDR:$http_port (redirects to HTTPS, loopback only)"
  fi
  log "InvenTree:   $(itree_inventree_ref)"
}

dev_banner() {
  warn "DEVELOPMENT MODE (--dev): password checks are skipped and the stack is bound to $ITREE_LOOPBACK_ADDR only."
  warn "Do not use --dev for a working instance. It uses the same data directory: $ITREE_VOLUME_ROOT"
}

render_for_start() {
  local dev="$1"
  if [ "$dev" = true ]; then
    dev_banner
    itree_render dev
  else
    itree_render strict
  fi
}

cmd_up() {
  local dev="$1"
  require_tools
  render_for_start "$dev" || exit 1
  provision_dirs
  preload_images
  log "Starting InvenTree stack from $project_root"
  itree_compose up -d --remove-orphans
  print_summary
  log "InvenTree is starting at $(cfg_get INVENTREE_SITE_URL)"
}

cmd_check() {
  local dev="$1"
  require_tools
  render_for_start "$dev" || exit 1
  itree_compose config --quiet
  print_summary
  log "Configuration OK (nothing was started)."
}

cmd_down() {
  require_tools
  itree_render lenient || true
  log "Stopping InvenTree stack from $project_root"
  itree_compose down --remove-orphans
  rm -f "$ITREE_ENV_FILE"
  log "Removed generated .env (.env.local is kept)"
}

generate_password() {
  # ITREE_GENERATED_PASSWORD_BYTES random bytes as hex (two characters each)
  local pw
  pw="$(dd if=/dev/urandom bs="$ITREE_GENERATED_PASSWORD_BYTES" count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  if [ "${#pw}" -ne $((ITREE_GENERATED_PASSWORD_BYTES * 2)) ]; then
    err "ERROR: could not generate a random password"
    return 1
  fi
  printf '%s' "$pw"
}

# write_local_secret KEY VALUE OUTFILE: write .env.local with KEY replaced (or
# appended) into OUTFILE, keeping every other line. The value is passed to awk
# through the environment, not the command line.
write_local_secret() {
  local key="$1" value="$2" out="$3"
  (umask 077 && : >"$out")
  chmod 600 "$out"
  if [ -f "$ITREE_LOCAL_FILE" ]; then
    ITREE_NEW_VALUE="$value" awk -v k="$key" '
      {
        line = $0
        sub(/^[[:space:]]*(export[[:space:]]+)?/, "", line)
        if (index(line, k "=") == 1) {
          if (!done) print k "=" ENVIRON["ITREE_NEW_VALUE"]
          done = 1
          next
        }
        print
      }
      END { if (!done) print k "=" ENVIRON["ITREE_NEW_VALUE"] }
    ' "$ITREE_LOCAL_FILE" >"$out"
  else
    {
      printf '# Local secrets for vl-itree (untracked). See .env.local.example.\n'
      ITREE_NEW_VALUE="$value" awk -v k="$key" 'BEGIN { print k "=" ENVIRON["ITREE_NEW_VALUE"] }'
    } >"$out"
  fi
}

cmd_rotate_db_password() {
  local db_user db_name new_pw pending started_db=false apps_running=false svc pinned_ref running_ref
  require_tools
  itree_render lenient || exit 1
  if ! db_initialized; then
    err "ERROR: no PostgreSQL data directory at $ITREE_PGDATA_DIR."
    err "For a new instance set INVENTREE_DB_PASSWORD in .env.local instead; PostgreSQL adopts it on first start."
    exit 1
  fi
  if [ -n "${INVENTREE_DB_PASSWORD+x}" ]; then
    err "ERROR: INVENTREE_DB_PASSWORD is set in the environment and would override .env.local."
    err "Unset it (unset INVENTREE_DB_PASSWORD) and run the rotation again."
    exit 1
  fi
  pending="$ITREE_LOCAL_PENDING_FILE"
  if [ -e "$pending" ]; then
    err "ERROR: $pending exists from an earlier rotation. Inspect it (it may hold the current password), then remove it."
    exit 1
  fi
  db_user="$(cfg_get INVENTREE_DB_USER)"
  db_name="$(cfg_get INVENTREE_DB_NAME)"

  for svc in "$ITREE_CT_SERVER" "$ITREE_CT_WORKER"; do
    if container_running "$svc"; then
      apps_running=true
    fi
  done
  if ! container_running "$ITREE_CT_DB"; then
    log "Starting the database container only"
    itree_compose up -d --no-deps --wait "$ITREE_CT_DB"
    started_db=true
  fi

  new_pw="$(generate_password)"
  write_local_secret INVENTREE_DB_PASSWORD "$new_pw" "$pending"

  log "Setting a new password for database role '$db_user' (value not shown)"
  # The password reaches psql through the environment (docker exec -e NAME
  # copies the value from this process), never through a command line, and
  # statement logging is disabled for the session. psql connects through the
  # container's local socket, which the postgres image trusts.
  if ! ITREE_NEW_DB_PASSWORD="$new_pw" docker exec -i -e ITREE_NEW_DB_PASSWORD "$ITREE_CT_DB" \
    psql -X -q -v ON_ERROR_STOP=1 -v db_user="$db_user" -U "$db_user" -d "$db_name" >/dev/null <<'SQL'; then
SET log_statement = 'none';
SET log_min_error_statement = 'panic';
SET log_min_duration_statement = -1;
\getenv new_password ITREE_NEW_DB_PASSWORD
ALTER ROLE :"db_user" PASSWORD :'new_password';
SQL
    rm -f "$pending"
    err "ERROR: ALTER ROLE failed; the database password and .env.local are unchanged."
    exit 1
  fi
  new_pw=""

  if ! mv -f "$pending" "$ITREE_LOCAL_FILE"; then
    err "ERROR: the database now uses the new password, but .env.local could not be updated."
    err "The new value is in $pending; move it to .env.local by hand."
    exit 1
  fi
  chmod 600 "$ITREE_LOCAL_FILE"
  log "Saved the new password to .env.local"
  # Keep the runtime .env in step with .env.local; "up" regenerates it anyway.
  itree_render lenient >/dev/null 2>&1 || true

  pinned_ref="$(itree_inventree_ref)"
  running_ref="$(docker inspect -f '{{.Config.Image}}' "$ITREE_CT_SERVER" 2>/dev/null || true)"
  if [ "$apps_running" = true ] && [ "$running_ref" != "$pinned_ref" ]; then
    # Recreating would also switch to the pinned image and run migrations,
    # i.e. upgrade without a backup. Stop instead; the old containers cannot
    # open new database connections with the old password anyway.
    log "Server runs $running_ref, not the pinned $pinned_ref."
    log "Stopping server and worker instead of recreating them (no upgrade without a backup)."
    itree_compose stop "$ITREE_CT_WORKER" "$ITREE_CT_SERVER"
    log "Next: bash run-itree-dump.sh --offline --no-restart, then bash run-itree.sh up"
  elif [ "$apps_running" = true ]; then
    if itree_render strict; then
      log "Recreating server and worker with the new password"
      itree_compose up -d --no-deps --force-recreate "$ITREE_CT_SERVER" "$ITREE_CT_WORKER"
    else
      err "The password was rotated, but the configuration check failed, so server and worker were not restarted."
      err "Fix the problems above, then run: bash run-itree.sh up"
      exit 1
    fi
  else
    if [ "$started_db" = true ]; then
      log "Stopping the database container again"
      itree_compose stop "$ITREE_CT_DB"
    fi
    log "Start the stack with: bash run-itree.sh up"
  fi
  log "Database password rotated."
}

cmd_export_ca() {
  local dest="${1:-$ITREE_CA_EXPORT_FILE}"
  require_tools
  itree_render lenient || exit 1
  if [ "$(cfg_get INVENTREE_PROXY_TLS)" != internal ]; then
    err "ERROR: export-ca applies to INVENTREE_TLS_MODE=internal with an https:// site URL only."
    exit 1
  fi
  if ! container_exists "$ITREE_CT_PROXY"; then
    err "ERROR: the $ITREE_CT_PROXY container does not exist; start the stack first (bash run-itree.sh up)."
    exit 1
  fi
  if ! docker cp "$ITREE_CT_PROXY:$ITREE_PROXY_CA_ROOT" "$dest" >/dev/null 2>&1; then
    err "ERROR: no internal CA root yet. Caddy creates it on the first HTTPS start; check: docker logs $ITREE_CT_PROXY"
    exit 1
  fi
  chmod 644 "$dest"
  log "Wrote the internal CA root certificate (public, not secret) to $dest"
  if command -v openssl >/dev/null 2>&1; then
    openssl x509 -in "$dest" -noout -subject -enddate -fingerprint -sha256
  fi
  log "Install it as a trusted CA on each client; see docs/network-tls.md, 'Client trust'."
}

image_version_label() {
  docker image inspect -f "{{index .Config.Labels \"$ITREE_IMAGE_VERSION_LABEL\"}}" "$1" 2>/dev/null || true
}

cmd_version() {
  local repo tag digest image_id label
  itree_render lenient >/dev/null 2>&1 || true
  log "Pinned images (docker/versions.env):"
  while read -r repo tag digest; do
    log "  $repo:$tag@$digest"
  done <<EOF
$(itree_images)
EOF
  if ! command -v docker >/dev/null 2>&1; then
    log "Deployed InvenTree: unknown (docker not available)"
    return 0
  fi
  if container_exists "$ITREE_CT_SERVER"; then
    image_id="$(docker inspect -f '{{.Image}}' "$ITREE_CT_SERVER")"
    label="$(image_version_label "$image_id")"
    log "Deployed InvenTree: ${label:-unknown} (container $ITREE_CT_SERVER, image $(docker inspect -f '{{.Config.Image}}' "$ITREE_CT_SERVER"))"
  elif docker image inspect "$ITREE_LEGACY_INVENTREE_IMAGE" >/dev/null 2>&1; then
    label="$(image_version_label "$ITREE_LEGACY_INVENTREE_IMAGE")"
    log "Deployed InvenTree: no container; cached $ITREE_LEGACY_INVENTREE_IMAGE is ${label:-unknown}"
  else
    log "Deployed InvenTree: unknown (no $ITREE_CT_SERVER container and no cached $ITREE_LEGACY_INVENTREE_IMAGE image)"
  fi
}

main() {
  local cmd="${1:-up}" dev=false arg
  if [ "$#" -gt 0 ]; then
    shift
  fi
  local rest=()
  for arg in "$@"; do
    case "$arg" in
      --dev) dev=true ;;
      -h | --help) usage; exit 0 ;;
      *) rest+=("$arg") ;;
    esac
  done

  case "$cmd" in
    up | start | run | check) ;;
    *)
      if [ "$dev" = true ]; then
        err "--dev is only valid with up or check"
        exit 2
      fi
      ;;
  esac
  local max_args=0
  if [ "$cmd" = export-ca ]; then
    max_args=1
  fi
  if [ "${#rest[@]}" -gt "$max_args" ]; then
    err "Unexpected argument: ${rest[$max_args]}"
    usage 1>&2
    exit 2
  fi

  log "Project root: $project_root"
  case "$cmd" in
    help | -h | --help) usage ;;
    up | start | run) cmd_up "$dev" ;;
    check) cmd_check "$dev" ;;
    down | stop | shutdown) cmd_down ;;
    rotate-db-password) cmd_rotate_db_password ;;
    export-ca) cmd_export_ca ${rest[@]+"${rest[@]}"} ;;
    version) cmd_version ;;
    *)
      err "Unknown command: $cmd"
      usage 1>&2
      exit 2
      ;;
  esac
}

main "$@"

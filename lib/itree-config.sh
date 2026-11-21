# shellcheck shell=bash
# shellcheck disable=SC2034  # constants are used by the scripts that source this file
#
# vl-itree shared constants: the single place for every path, name, list and
# limit used by run-itree.sh, run-itree-dump.sh, lib/itree-common.sh and
# tests/test-launcher.sh.
#
# Sourced by lib/itree-common.sh (and directly by the tests). The caller must
# set "project_root" (absolute path of the repository) first. This file only
# assigns variables; it defines no functions and runs no commands.
#
# What lives where:
#   lib/itree-config.sh   (this file) fixed script constants: file locations,
#                         container names, in-container paths, backup
#                         contents, password policy. Change them here only.
#   docker/env.template   deployment defaults the owner may override in
#                         .env.local: ports, bind address, site URL, TLS mode,
#                         InvenTree settings.
#   docker/versions.env   pinned image tags and digests.
#
# Values marked "keep in sync" are also written literally in
# docker/docker-compose.yml or docker/Caddyfile; change both together.
# Reference: docs/configuration.md, section "Script constants".

: "${project_root:?set project_root before sourcing lib/itree-config.sh}"

# ---------------------------------------------------------------------------
# Requirements
# ---------------------------------------------------------------------------

# Oldest Docker Compose that supports healthcheck-gated depends_on and --wait.
ITREE_MIN_COMPOSE_VERSION="2.20.0"

# ---------------------------------------------------------------------------
# Repository files (tracked)
# ---------------------------------------------------------------------------

ITREE_DOCKER_DIR="$project_root/docker"
ITREE_COMPOSE_FILE="$ITREE_DOCKER_DIR/docker-compose.yml"
# Overlay added when INVENTREE_TLS_MODE=owner.
ITREE_COMPOSE_TLS_OWNER_FILE="$ITREE_DOCKER_DIR/docker-compose.tls-owner.yml"
ITREE_TEMPLATE_FILE="$ITREE_DOCKER_DIR/env.template"
ITREE_VERSIONS_FILE="$ITREE_DOCKER_DIR/versions.env"
ITREE_CADDYFILE="$ITREE_DOCKER_DIR/Caddyfile"
ITREE_LOCAL_EXAMPLE_FILE="$project_root/.env.local.example"

# Upstream source of docker/Caddyfile. Removing the "vl-itree: begin/end"
# blocks from docker/Caddyfile must give a file with this sha256.
ITREE_CADDYFILE_UPSTREAM_TAG="1.7.3"
ITREE_CADDYFILE_UPSTREAM_SHA256="df6ca810f79b328ad47f451035450fbac261e5b0298c7e1b06b2027f316b2544"

# ---------------------------------------------------------------------------
# Local files and directories (untracked, see .gitignore)
# ---------------------------------------------------------------------------

# Owner secrets and overrides. Never deleted; only rotate-db-password
# rewrites its INVENTREE_DB_PASSWORD line.
ITREE_LOCAL_FILE="$project_root/.env.local"
# Written before ALTER ROLE and moved over ITREE_LOCAL_FILE after it succeeds.
ITREE_LOCAL_PENDING_FILE="$ITREE_LOCAL_FILE.pending"
# Runtime file generated on every start (mode 600); removed by "down".
# Keep in sync: docker-compose.yml "env_file: ../.env".
ITREE_ENV_FILE="$project_root/.env"
# Persistent data, mounted as INVENTREE_EXT_VOLUME.
ITREE_VOLUME_ROOT="$project_root/inventree-volume"
# PostgreSQL data directory inside the volume. Keep in sync: PGDATA in
# docker-compose.yml.
ITREE_PGDATA_DIR="$ITREE_VOLUME_ROOT/pgdb"
# Subdirectories of the volume created before the first start (relative to
# ITREE_VOLUME_ROOT). Keep in sync: volume mounts in docker-compose.yml.
ITREE_VOLUME_DIRS="static media redis caddy/data caddy/config caddy/log"
# Backups written by run-itree-dump.sh.
ITREE_DUMP_ROOT="$project_root/inventree-dump"
# Image tarball cache used by "up".
ITREE_IMAGES_CACHE_DIR="$project_root/docker-images"
# Default target of "export-ca" (public certificate; *.crt is gitignored).
ITREE_CA_EXPORT_FILE="$project_root/inventree-root-ca.crt"

# ---------------------------------------------------------------------------
# Containers (keep in sync: container_name in docker-compose.yml; the Compose
# service names are the same strings)
# ---------------------------------------------------------------------------

ITREE_CT_DB="inventree-db"
ITREE_CT_CACHE="inventree-cache"
ITREE_CT_SERVER="inventree-server"
ITREE_CT_WORKER="inventree-worker"
ITREE_CT_PROXY="inventree-proxy"

# Paths inside containers
# The whole data volume as mounted in the database container (keep in sync:
# inventree-db volume in docker-compose.yml).
ITREE_DB_DATA_DIR="/var/lib/postgresql/data"
# Root certificate of Caddy's internal CA (Caddy's /data is mounted from
# caddy/data in the volume).
ITREE_PROXY_CA_ROOT="/data/caddy/pki/authorities/local/root.crt"

# ---------------------------------------------------------------------------
# Images
# ---------------------------------------------------------------------------

# One "<PREFIX> <repository>" per line. Each prefix has <PREFIX>_TAG and
# <PREFIX>_DIGEST in docker/versions.env. Keep in sync: image: lines in
# docker-compose.yml.
ITREE_IMAGE_TABLE="INVENTREE inventree/inventree
POSTGRES postgres
REDIS redis
CADDY caddy"
# Floating tag used by deployments before tag pinning (read by "version").
ITREE_LEGACY_INVENTREE_IMAGE="inventree/inventree:stable"
# OCI label that carries the InvenTree version in the image.
ITREE_IMAGE_VERSION_LABEL="org.opencontainers.image.version"

# ---------------------------------------------------------------------------
# Configuration keys
# ---------------------------------------------------------------------------

# Keys that may also come from the process environment (credentials only).
ITREE_ENV_KEYS="INVENTREE_DB_PASSWORD INVENTREE_ADMIN_USER INVENTREE_ADMIN_EMAIL INVENTREE_ADMIN_PASSWORD"
# Keys owned by docker/versions.env; ignored when set in .env.local.
ITREE_PINNED_KEYS="INVENTREE_TAG INVENTREE_DIGEST POSTGRES_TAG POSTGRES_DIGEST REDIS_TAG REDIS_DIGEST CADDY_TAG CADDY_DIGEST"
# Keys computed by the launcher; ignored when set in .env.local.
ITREE_COMPUTED_KEYS="INVENTREE_EXT_VOLUME INVENTREE_PROXY_TLS INVENTREE_SESSION_COOKIE_SECURE"
# Keys fixed by docker/env.template; ignored when set in .env.local.
# COMPOSE_PROJECT_NAME must stay "docker" (the name used by earlier versions).
ITREE_TEMPLATE_ONLY_KEYS="COMPOSE_PROJECT_NAME"

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

# Loopback address: forced bind address in --dev, and the Host header of the
# proxy's internal health check (always allowed in INVENTREE_ALLOWED_HOSTS).
# Keep in sync: the HTTP port binding in docker-compose.yml.
ITREE_LOOPBACK_ADDR="127.0.0.1"

# ---------------------------------------------------------------------------
# Password policy
# ---------------------------------------------------------------------------

ITREE_MIN_SECRET_LENGTH=16
# Template value; refused for a working instance.
ITREE_PLACEHOLDER="__CHANGE_ME__"
# Lower-case values refused as passwords.
ITREE_KNOWN_DEFAULTS="inventree pgpassword pguser postgres password admin administrator root secret changeme letmein"
# Random bytes for rotate-db-password; the password is their hex form
# (twice as many characters).
ITREE_GENERATED_PASSWORD_BYTES=32

# ---------------------------------------------------------------------------
# Backups (run-itree-dump.sh); paths relative to the data volume
# ---------------------------------------------------------------------------

ITREE_DUMP_TIMESTAMP_FORMAT="%Y%m%d-%H%M%S"
ITREE_DUMP_DB_FILE="db.dump"
ITREE_DUMP_KEYS_FILE="keys.tar.gz"
ITREE_DUMP_ASSETS_FILE="assets.tar.gz"
ITREE_DUMP_METADATA_FILE="metadata.txt"
ITREE_DUMP_CHECKSUM_FILE="SHA256SUMS"
# keys.tar.gz: the backup fails if one of these is missing. secret_key.txt
# peppers API tokens since InvenTree 1.6.0.
ITREE_BACKUP_REQUIRED_KEYS="secret_key.txt config.yaml"
# keys.tar.gz: included when present (OIDC signing key, plugin list, Caddy CA).
ITREE_BACKUP_OPTIONAL_KEYS="oidc.pem plugins.txt caddy/data"
# assets.tar.gz: included when present.
ITREE_BACKUP_ASSET_DIRS="media static plugins config"
# Services stopped during a backup.
ITREE_BACKUP_STOP_QUIESCED="$ITREE_CT_WORKER $ITREE_CT_SERVER"
ITREE_BACKUP_STOP_OFFLINE="$ITREE_CT_PROXY $ITREE_CT_WORKER $ITREE_CT_SERVER $ITREE_CT_CACHE"

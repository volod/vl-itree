# shellcheck shell=bash
#
# Shared helpers for run-itree.sh and run-itree-dump.sh.
# Source this file after setting "project_root"; do not execute it. It loads
# lib/itree-config.sh, which holds every constant these helpers use.
#
# Configuration is merged, never sourced: files are parsed as KEY=VALUE text so
# that nothing in .env.local can run as shell code. Secret values are kept in
# shell variables and files with mode 0600 and are never printed. Error
# messages name the offending key, never its value.

# Constants (paths, container names, key lists, policy): lib/itree-config.sh
# shellcheck source=lib/itree-config.sh
. "${project_root:?set project_root before sourcing lib/itree-common.sh}/lib/itree-config.sh"

# State filled by itree_render.
ITREE_CFG=""
ITREE_ERRORS=0
compose_files=()
site_scheme=""
site_host=""
site_port=""

log() {
  printf '%s\n' "$*"
}

err() {
  printf '%s\n' "$*" 1>&2
}

warn() {
  printf 'WARNING: %s\n' "$*" 1>&2
}

version_ge() {
  # Returns 0 if $1 >= $2 (dotted versions)
  [ "$(printf '%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

require_tools() {
  if ! command -v docker >/dev/null 2>&1; then
    err "Docker is not installed or not in PATH"
    exit 1
  fi
  local raw_version version_number
  if ! raw_version="$(docker compose version 2>/dev/null | tr -d '\r')"; then
    err "Docker Compose v2 (docker compose) is required"
    exit 1
  fi
  version_number="$(printf '%s' "$raw_version" | sed -nE 's/.*v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')"
  if [ -z "$version_number" ]; then
    err "Unable to parse Docker Compose version from: $raw_version"
    exit 1
  fi
  if ! version_ge "$version_number" "$ITREE_MIN_COMPOSE_VERSION"; then
    err "Docker Compose v$ITREE_MIN_COMPOSE_VERSION or newer required (healthcheck-gated depends_on, --wait), found v$version_number"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# KEY=VALUE parsing and merging
# ---------------------------------------------------------------------------

# kv_parse FILE: print normalized KEY=VALUE lines. Blank lines and comments are
# skipped, an optional "export " prefix is dropped, one pair of surrounding
# quotes is removed, and " #..." is stripped from unquoted values. Lines are
# never echoed in diagnostics, because they may hold secrets.
kv_parse() {
  awk -v q="'" -v file="$(basename -- "$1")" '
    { sub(/\r$/, "") }
    /^[[:space:]]*(#|$)/ { next }
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      sub(/^export[[:space:]]+/, "", line)
      eq = index(line, "=")
      if (eq == 0) {
        printf "%s:%d: line has no \"=\"\n", file, FNR > "/dev/stderr"
        bad = 1
        next
      }
      key = substr(line, 1, eq - 1)
      val = substr(line, eq + 1)
      sub(/[[:space:]]+$/, "", key)
      if (key !~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
        printf "%s:%d: invalid variable name\n", file, FNR > "/dev/stderr"
        bad = 1
        next
      }
      sub(/^[[:space:]]+/, "", val)
      sub(/[[:space:]]+$/, "", val)
      first = substr(val, 1, 1)
      last = substr(val, length(val), 1)
      if (length(val) >= 2 && first == last && (first == q || first == "\"")) {
        val = substr(val, 2, length(val) - 2)
      } else {
        sub(/[[:space:]]+#.*$/, "", val)
      }
      print key "=" val
    }
    END { exit bad }
  ' "$1"
}

# kv_merge: read KEY=VALUE lines on stdin; the last value of a key wins and
# keys keep the order in which they first appeared.
kv_merge() {
  awk '
    {
      eq = index($0, "=")
      if (eq == 0) next
      k = substr($0, 1, eq - 1)
      if (!(k in v)) order[++n] = k
      v[k] = substr($0, eq + 1)
    }
    END { for (i = 1; i <= n; i++) print order[i] "=" v[order[i]] }
  '
}

# cfg_get KEY: print the merged value of KEY (empty if unset).
cfg_get() {
  printf '%s\n' "$ITREE_CFG" | awk -v k="$1" '
    index($0, k "=") == 1 { v = substr($0, length(k) + 2); f = 1 }
    END { if (f) print v }
  '
}

# cfg_set KEY VALUE
cfg_set() {
  ITREE_CFG="$(printf '%s\n%s=%s\n' "$ITREE_CFG" "$1" "$2" | kv_merge)"
}

cfg_keys() {
  printf '%s\n' "$ITREE_CFG" | cut -d= -f1
}

# ---------------------------------------------------------------------------
# Validation helpers
# ---------------------------------------------------------------------------

# problem LEVEL MESSAGE: LEVEL is "fatal" (always an error), "secret"
# (error only when secrets are enforced) or "warn".
problem() {
  local level="$1"
  shift
  case "$level" in
    fatal)
      if [ "$ITREE_FATAL" = true ]; then
        err "ERROR: $*"
        ITREE_ERRORS=$((ITREE_ERRORS + 1))
      else
        warn "$*"
      fi
      ;;
    secret)
      if [ "$ITREE_ENFORCE_SECRETS" = true ]; then
        err "ERROR: $*"
        ITREE_ERRORS=$((ITREE_ERRORS + 1))
      else
        warn "$*"
      fi
      ;;
    *)
      warn "$*"
      ;;
  esac
}

# secret_problem VALUE [USERNAME]: print why VALUE is not acceptable as a
# password, or nothing if it is. Never prints VALUE.
secret_problem() {
  local value="$1" user="${2:-}" lower d
  if [ -z "$value" ]; then
    printf 'is missing or empty'
    return 0
  fi
  lower="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *change_me* | *changeme* | "<"*">")
      printf 'is still a placeholder'
      return 0
      ;;
  esac
  for d in $ITREE_KNOWN_DEFAULTS; do
    if [ "$lower" = "$d" ]; then
      printf 'equals a well-known default value'
      return 0
    fi
  done
  if [ -n "$user" ] && [ "$lower" = "$(printf '%s' "$user" | tr '[:upper:]' '[:lower:]')" ]; then
    printf 'equals the user name'
    return 0
  fi
  if [ "${#value}" -lt "$ITREE_MIN_SECRET_LENGTH" ]; then
    printf 'is shorter than %s characters' "$ITREE_MIN_SECRET_LENGTH"
    return 0
  fi
  case "$value" in
    *[[:space:]\'\"\\\`\$#]*)
      printf 'contains a forbidden character (whitespace, quote, backslash, backtick, $ or #)'
      return 0
      ;;
  esac
  return 0
}

is_ipv4() {
  local ip="$1" part
  case "$ip" in
    *[!0-9.]* | .* | *. | *..*) return 1 ;;
  esac
  local IFS=.
  # shellcheck disable=SC2086
  set -- $ip
  [ "$#" -eq 4 ] || return 1
  for part in "$@"; do
    [ "${#part}" -le 3 ] || return 1
    [ "$part" -le 255 ] 2>/dev/null || return 1
  done
  return 0
}

is_loopback_ip() {
  is_ipv4 "$1" && case "$1" in 127.*) return 0 ;; *) return 1 ;; esac
}

is_loopback_host() {
  case "$1" in
    localhost | *.localhost) return 0 ;;
  esac
  is_loopback_ip "$1"
}

is_port() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# resolve_path PATH: print the absolute, symlink-free path of an existing file.
resolve_path() {
  local target="$1" dir base
  while [ -L "$target" ]; do
    dir="$(cd -P -- "$(dirname -- "$target")" && pwd)"
    target="$(readlink -- "$target")"
    case "$target" in
      /*) ;;
      *) target="$dir/$target" ;;
    esac
  done
  dir="$(cd -P -- "$(dirname -- "$target")" && pwd)" || return 1
  base="$(basename -- "$target")"
  printf '%s/%s\n' "$dir" "$base"
}

# parse_site_url URL: set site_scheme, site_host, site_port.
parse_site_url() {
  local url="$1" rest
  site_scheme=""
  site_host=""
  site_port=""
  case "$url" in
    http://*) site_scheme=http; rest="${url#http://}" ;;
    https://*) site_scheme=https; rest="${url#https://}" ;;
    *) return 1 ;;
  esac
  rest="${rest%/}"
  case "$rest" in
    '' | */* | *\?* | *\#* | *@* | \[*) return 1 ;;
  esac
  case "$rest" in
    *:*) site_host="${rest%%:*}"; site_port="${rest#*:}" ;;
    *)
      site_host="$rest"
      if [ "$site_scheme" = https ]; then site_port=443; else site_port=80; fi
      ;;
  esac
  case "$site_host" in
    '' | *[!A-Za-z0-9.-]* | -* | .*) return 1 ;;
  esac
  is_port "$site_port"
}

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

# itree_render MODE: merge and validate the configuration, then write the
# runtime .env. MODE is one of:
#   strict  - working instance: every check is enforced
#   dev     - development: password checks become warnings, binding is forced
#             to loopback and a non-loopback site URL is replaced
#   lenient - maintenance (down, dump, rotation): problems are warnings
# Returns non-zero (after printing every problem) if the configuration is
# refused. Never prints secret values.
itree_render() {
  local mode="$1" parsed key value k reason bind http_port https_port tls_mode
  local site_url cert_file key_file cert_real key_real admin_user admin_email admin_pw
  ITREE_ERRORS=0
  case "$mode" in
    strict) ITREE_FATAL=true; ITREE_ENFORCE_SECRETS=true ;;
    dev) ITREE_FATAL=true; ITREE_ENFORCE_SECRETS=false ;;
    lenient) ITREE_FATAL=false; ITREE_ENFORCE_SECRETS=false ;;
    *) err "itree_render: unknown mode $mode"; return 2 ;;
  esac

  for k in "$ITREE_TEMPLATE_FILE" "$ITREE_VERSIONS_FILE" "$ITREE_COMPOSE_FILE"; do
    if [ ! -f "$k" ]; then
      err "ERROR: required file not found: $k"
      return 1
    fi
  done

  # 1. template
  if ! parsed="$(kv_parse "$ITREE_TEMPLATE_FILE")"; then
    err "ERROR: cannot parse $ITREE_TEMPLATE_FILE"
    return 1
  fi
  ITREE_CFG="$(printf '%s\n' "$parsed" | kv_merge)"

  # 2. .env.local
  if [ -f "$ITREE_LOCAL_FILE" ]; then
    if [ -n "$(find "$ITREE_LOCAL_FILE" -prune \( -perm -040 -o -perm -004 \) 2>/dev/null)" ]; then
      warn ".env.local is readable by group or others; run: chmod 600 .env.local"
    fi
    if ! parsed="$(kv_parse "$ITREE_LOCAL_FILE")"; then
      err "ERROR: cannot parse .env.local (see line numbers above)"
      return 1
    fi
    for k in $ITREE_PINNED_KEYS $ITREE_COMPUTED_KEYS $ITREE_TEMPLATE_ONLY_KEYS; do
      if printf '%s\n' "$parsed" | grep -q "^$k="; then
        warn ".env.local sets $k, which is managed elsewhere; the value is ignored"
        parsed="$(printf '%s\n' "$parsed" | grep -v "^$k=" || true)"
      fi
    done
    ITREE_CFG="$(printf '%s\n%s\n' "$ITREE_CFG" "$parsed" | kv_merge)"
  fi

  # 3. process environment (credential keys only)
  for k in $ITREE_ENV_KEYS; do
    if [ -n "${!k+x}" ]; then
      cfg_set "$k" "${!k}"
    fi
  done

  # 4. pinned images
  if ! parsed="$(kv_parse "$ITREE_VERSIONS_FILE")"; then
    err "ERROR: cannot parse $ITREE_VERSIONS_FILE"
    return 1
  fi
  ITREE_CFG="$(printf '%s\n%s\n' "$ITREE_CFG" "$parsed" | kv_merge)"
  for k in $(itree_image_prefixes); do
    value="$(cfg_get "${k}_TAG")"
    case "$value" in
      '' | stable | latest | *[!A-Za-z0-9._-]*)
        problem fatal "${k}_TAG in docker/versions.env must be an exact version tag (not stable or latest)"
        ;;
    esac
    value="$(cfg_get "${k}_DIGEST")"
    if ! printf '%s' "$value" | grep -Eq '^sha256:[0-9a-f]{64}$'; then
      problem fatal "${k}_DIGEST in docker/versions.env must be sha256:<64 hex digits>"
    fi
  done

  # 5. network exposure
  http_port="$(cfg_get INVENTREE_HTTP_PORT)"
  https_port="$(cfg_get INVENTREE_HTTPS_PORT)"
  is_port "$http_port" || problem fatal "INVENTREE_HTTP_PORT must be a port number"
  is_port "$https_port" || problem fatal "INVENTREE_HTTPS_PORT must be a port number"
  if [ "$http_port" = "$https_port" ]; then
    problem fatal "INVENTREE_HTTP_PORT and INVENTREE_HTTPS_PORT must differ"
  fi

  bind="$(cfg_get INVENTREE_BIND_ADDR)"
  if [ "$mode" = dev ]; then
    if [ "$bind" != "$ITREE_LOOPBACK_ADDR" ]; then
      warn "--dev: INVENTREE_BIND_ADDR '$bind' replaced by $ITREE_LOOPBACK_ADDR"
    fi
    bind="$ITREE_LOOPBACK_ADDR"
    cfg_set INVENTREE_BIND_ADDR "$bind"
  fi
  if ! is_ipv4 "$bind"; then
    problem fatal "INVENTREE_BIND_ADDR must be an IPv4 address (for example 127.0.0.1, a LAN address, or 0.0.0.0)"
  fi

  site_url="$(cfg_get INVENTREE_SITE_URL)"
  if [ "$mode" = dev ] && parse_site_url "$site_url" && ! is_loopback_host "$site_host"; then
    warn "--dev: INVENTREE_SITE_URL '$site_url' replaced by http://localhost:$http_port"
    site_url="http://localhost:$http_port"
    cfg_set INVENTREE_SITE_URL "$site_url"
  fi
  if ! parse_site_url "$site_url"; then
    problem fatal "INVENTREE_SITE_URL must look like https://host[:port] (no path, query, credentials or IPv6 literal)"
    site_scheme=""
  fi

  if [ "$site_scheme" = http ] && is_ipv4 "$bind" && ! is_loopback_ip "$bind"; then
    problem fatal "INVENTREE_BIND_ADDR '$bind' is not loopback but INVENTREE_SITE_URL uses http://. Remote access requires an https:// site URL."
  fi
  if [ "$site_scheme" = https ] && [ "$site_port" != "$https_port" ]; then
    problem fatal "INVENTREE_SITE_URL port $site_port must equal INVENTREE_HTTPS_PORT ($https_port)"
  fi
  if [ "$site_scheme" = http ] && [ "$site_port" != "$http_port" ]; then
    problem fatal "INVENTREE_SITE_URL port $site_port must equal INVENTREE_HTTP_PORT ($http_port)"
  fi

  # 6. TLS
  tls_mode="$(cfg_get INVENTREE_TLS_MODE)"
  compose_files=(-f "$ITREE_COMPOSE_FILE")
  if [ "$site_scheme" = https ]; then
    case "$tls_mode" in
      internal)
        cfg_set INVENTREE_PROXY_TLS internal
        ;;
      owner)
        cfg_set INVENTREE_PROXY_TLS owner
        cert_file="$(cfg_get INVENTREE_TLS_CERT_FILE)"
        key_file="$(cfg_get INVENTREE_TLS_KEY_FILE)"
        if itree_check_owner_tls "$cert_file" "$key_file"; then
          cert_real="$(resolve_path "$cert_file")"
          key_real="$(resolve_path "$key_file")"
          cfg_set INVENTREE_TLS_CERT_FILE "$cert_real"
          cfg_set INVENTREE_TLS_KEY_FILE "$key_real"
          compose_files+=(-f "$ITREE_COMPOSE_TLS_OWNER_FILE")
        fi
        ;;
      *)
        problem fatal "INVENTREE_TLS_MODE must be 'internal' or 'owner' for an https:// site URL"
        cfg_set INVENTREE_PROXY_TLS internal
        ;;
    esac
    cfg_set INVENTREE_SESSION_COOKIE_SECURE True
  else
    cfg_set INVENTREE_PROXY_TLS none
    cfg_set INVENTREE_SESSION_COOKIE_SECURE False
  fi

  # 7. Django host and origin lists, unless the owner set them explicitly
  if [ -n "$site_host" ]; then
    if [ -z "$(cfg_get INVENTREE_ALLOWED_HOSTS)" ]; then
      # ITREE_LOOPBACK_ADDR is the Host header of the proxy's internal :9090 health
      # check; external requests cannot reach Django with it because Caddy
      # only routes the site host.
      if [ "$site_host" = "$ITREE_LOOPBACK_ADDR" ]; then
        cfg_set INVENTREE_ALLOWED_HOSTS "$site_host"
      else
        cfg_set INVENTREE_ALLOWED_HOSTS "$site_host,$ITREE_LOOPBACK_ADDR"
      fi
    fi
    if [ -z "$(cfg_get INVENTREE_TRUSTED_ORIGINS)" ]; then
      cfg_set INVENTREE_TRUSTED_ORIGINS "${site_url%/}"
    fi
  fi

  # 8. secrets
  value="$(cfg_get INVENTREE_DB_PASSWORD)"
  reason="$(secret_problem "$value" "$(cfg_get INVENTREE_DB_USER)")"
  if [ -n "$reason" ]; then
    if [ -f "$ITREE_LOCAL_FILE" ]; then
      problem secret "INVENTREE_DB_PASSWORD $reason. Set a strong value in .env.local (existing instance: run 'bash run-itree.sh rotate-db-password')."
    else
      problem secret "INVENTREE_DB_PASSWORD $reason. Create .env.local from .env.local.example (existing instance: run 'bash run-itree.sh rotate-db-password')."
    fi
  fi
  if [ -z "$value" ]; then
    # Compose cannot run without a value, even in dev or lenient mode.
    cfg_set INVENTREE_DB_PASSWORD "$ITREE_PLACEHOLDER"
  fi
  admin_user="$(cfg_get INVENTREE_ADMIN_USER)"
  admin_email="$(cfg_get INVENTREE_ADMIN_EMAIL)"
  admin_pw="$(cfg_get INVENTREE_ADMIN_PASSWORD)"
  if [ -n "$admin_user$admin_email$admin_pw" ]; then
    if [ -z "$admin_user" ] || [ -z "$admin_email" ]; then
      problem secret "INVENTREE_ADMIN_USER, INVENTREE_ADMIN_EMAIL and INVENTREE_ADMIN_PASSWORD must be set together"
    fi
    reason="$(secret_problem "$admin_pw" "$admin_user")"
    if [ -n "$reason" ]; then
      problem secret "INVENTREE_ADMIN_PASSWORD $reason"
    fi
  fi

  # 9. computed paths
  cfg_set INVENTREE_EXT_VOLUME "$ITREE_VOLUME_ROOT"

  # Every value goes into the runtime .env inside single quotes.
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    case "$(cfg_get "$key")" in
      *"'"*) problem fatal "$key contains a single quote, which the runtime .env cannot carry" ;;
    esac
  done <<EOF
$(cfg_keys)
EOF

  if [ "$ITREE_ERRORS" -gt 0 ]; then
    err "Refusing to continue: $ITREE_ERRORS configuration problem(s). No containers were started or changed."
    return 1
  fi
  itree_write_env
}

# itree_check_owner_tls CERT KEY: validate owner-supplied certificate files.
itree_check_owner_tls() {
  local cert="$1" key="$2" f real ok=0 out cert_pub key_pub
  for f in "$cert" "$key"; do
    case "$f" in
      '')
        problem fatal "INVENTREE_TLS_MODE=owner needs INVENTREE_TLS_CERT_FILE and INVENTREE_TLS_KEY_FILE"
        return 1
        ;;
      /*) ;;
      *)
        problem fatal "TLS certificate and key paths must be absolute: $f"
        ok=1
        continue
        ;;
    esac
    if [ ! -f "$f" ]; then
      problem fatal "TLS file not found or not a regular file: $f"
      ok=1
      continue
    fi
    real="$(resolve_path "$f")"
    case "$real/" in
      "$project_root"/*)
        problem fatal "TLS file must live outside the repository: $f"
        ok=1
        ;;
    esac
  done
  [ "$ok" -eq 0 ] || return 1

  if [ -n "$(find "$key" -prune -perm -004 2>/dev/null)" ]; then
    problem fatal "TLS key file is world-readable; run: chmod 600 $key"
    return 1
  fi
  if ! command -v openssl >/dev/null 2>&1; then
    warn "openssl not found; skipping certificate checks"
    return 0
  fi
  if [ -r "$cert" ]; then
    if ! openssl x509 -in "$cert" -noout >/dev/null 2>&1; then
      problem fatal "INVENTREE_TLS_CERT_FILE is not a PEM certificate"
      return 1
    fi
    if ! openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1; then
      problem fatal "the TLS certificate has expired"
    fi
    if is_ipv4 "$site_host"; then
      out="$(openssl x509 -in "$cert" -noout -checkip "$site_host" 2>/dev/null || true)"
    else
      out="$(openssl x509 -in "$cert" -noout -checkhost "$site_host" 2>/dev/null || true)"
    fi
    case "$out" in
      *"does match"*) ;;
      *) problem fatal "the TLS certificate does not cover '$site_host' from INVENTREE_SITE_URL" ;;
    esac
    if [ -r "$key" ]; then
      cert_pub="$(openssl x509 -in "$cert" -noout -pubkey 2>/dev/null | openssl sha256 2>/dev/null || true)"
      key_pub="$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl sha256 2>/dev/null || true)"
      if [ -z "$key_pub" ] || [ "$cert_pub" != "$key_pub" ]; then
        problem fatal "INVENTREE_TLS_KEY_FILE does not match INVENTREE_TLS_CERT_FILE"
      fi
    fi
  else
    warn "cannot read $cert as $(id -un); skipping certificate checks"
  fi
  return 0
}

itree_write_env() {
  local tmp
  tmp="$(umask 077 && mktemp "$project_root/.env.tmp.XXXXXX")"
  {
    printf '# GENERATED by run-itree.sh - do not edit. Regenerated on every start.\n'
    printf '# Sources: docker/env.template, .env.local, environment, docker/versions.env.\n'
    printf '%s\n' "$ITREE_CFG" | awk -v q="'" '
      { eq = index($0, "="); if (eq == 0) next; print substr($0, 1, eq - 1) "=" q substr($0, eq + 1) q }
    '
  } >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$ITREE_ENV_FILE"
}

# itree_compose ARGS...: run docker compose against the rendered .env. Keys of
# the rendered configuration are removed from the environment first, so a
# stray exported variable cannot override validated values.
itree_compose() {
  (
    while IFS= read -r key; do
      [ -n "$key" ] && unset "$key"
    done <<EOF
$(cfg_keys)
EOF
    unset COMPOSE_FILE COMPOSE_PROFILES COMPOSE_PROJECT_NAME
    cd "$project_root" || exit 1
    exec docker compose --env-file "$ITREE_ENV_FILE" "${compose_files[@]}" "$@"
  )
}

# Image prefixes from ITREE_IMAGE_TABLE (INVENTREE POSTGRES ...).
itree_image_prefixes() {
  printf '%s\n' "$ITREE_IMAGE_TABLE" | awk 'NF { print $1 }'
}

# Pinned image references, one "repo tag digest" per line.
itree_images() {
  local prefix repo
  while read -r prefix repo; do
    [ -n "$prefix" ] || continue
    printf '%s %s %s\n' "$repo" "$(cfg_get "${prefix}_TAG")" "$(cfg_get "${prefix}_DIGEST")"
  done <<EOF
$ITREE_IMAGE_TABLE
EOF
}

# itree_image_repo PREFIX: repository of PREFIX in ITREE_IMAGE_TABLE.
itree_image_repo() {
  printf '%s\n' "$ITREE_IMAGE_TABLE" | awk -v p="$1" '$1 == p { print $2 }'
}

# Pinned reference of the InvenTree image (repo:tag@digest).
itree_inventree_ref() {
  printf '%s:%s@%s' "$(itree_image_repo INVENTREE)" "$(cfg_get INVENTREE_TAG)" "$(cfg_get INVENTREE_DIGEST)"
}

container_running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" = true ]
}

container_exists() {
  docker inspect "$1" >/dev/null 2>&1
}

# The PostgreSQL data directory is owned by the container's postgres user and
# is usually unreadable from the host; treat "exists but unreadable" as
# initialized.
db_initialized() {
  local pgdata="$ITREE_PGDATA_DIR"
  [ -d "$pgdata" ] || return 1
  if [ -r "$pgdata" ] && [ -x "$pgdata" ]; then
    [ -f "$pgdata/PG_VERSION" ]
  else
    return 0
  fi
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@"
  else
    shasum -a 256 "$@"
  fi
}

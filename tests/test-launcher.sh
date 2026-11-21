#!/usr/bin/env bash

set -euo pipefail

# Offline tests for run-itree.sh. Nothing here starts, stops or pulls a
# container, and nothing touches inventree-volume/, inventree-dump/ or .env*
# of the real checkout:
# - the scripts and docker/ files are copied into a throwaway directory;
# - a "docker" shim on PATH passes only "docker compose version" and
#   "docker compose ... config" to the real docker and fails on anything else,
#   so a refused start provably never reached Docker;
# - all passwords are dummy values generated per run.
#
# Usage: bash tests/test-launcher.sh

repo_root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"
# Shared constants (container names, upstream Caddyfile hash, ...)
project_root="$repo_root"
# shellcheck source=lib/itree-config.sh
. "$repo_root/lib/itree-config.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/vl-itree-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS  %s\n' "$*"; }
ko() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$*"; }

real_docker="$(command -v docker || true)"
have_compose=false
if [ -n "$real_docker" ] && "$real_docker" compose version >/dev/null 2>&1; then
  have_compose=true
fi

# Throwaway copy of the deployable files (no data, no secrets)
copy="$work/vl-itree"
mkdir -p "$copy"
cp -R "$repo_root/run-itree.sh" "$repo_root/run-itree-dump.sh" "$repo_root/lib" \
  "$repo_root/docker" "$repo_root/.env.local.example" "$copy/"
rm -f "$copy/docker/.env"

# docker shim
mkdir -p "$work/bin"
cat >"$work/bin/docker" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$work/docker-calls.log"
if [ "\${1:-}" = compose ] && [ "\${2:-}" = version ]; then
  exec "$real_docker" "\$@"
fi
if [ "\${1:-}" = compose ]; then
  for a in "\$@"; do
    if [ "\$a" = config ]; then
      # Record what compose interpolation sees for a non-secret key
      printf 'ENV INVENTREE_BIND_ADDR=%s\n' "\${INVENTREE_BIND_ADDR-<unset>}" >>"$work/docker-env.log"
      exec "$real_docker" "\$@"
    fi
  done
fi
echo "docker shim: refusing 'docker \$*' during tests" >&2
exit 99
SHIM
chmod +x "$work/bin/docker"

# Dummy, non-default secrets for this run only
dummy_pw="dummy-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
dummy_admin_pw="dummyadmin-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"

# Owner TLS fixtures outside the copy
tls_dir="$work/owner-tls"
mkdir -p "$tls_dir"
have_openssl=false
if command -v openssl >/dev/null 2>&1; then
  have_openssl=true
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=inventree.lan \
    -addext subjectAltName=DNS:inventree.lan -keyout "$tls_dir/key.pem" \
    -out "$tls_dir/cert.pem" >/dev/null 2>&1
  chmod 600 "$tls_dir/key.pem"
fi

write_local() {
  # write_local LINE...: replace .env.local in the copy
  rm -f "$copy/.env.local"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" >"$copy/.env.local"
    chmod 600 "$copy/.env.local"
  fi
}

# run_launcher ARGS...: run the copy with a clean environment plus extra
# NAME=VALUE pairs from LAUNCH_ENV; sets out, rc
LAUNCH_ENV=()
run_launcher() {
  rm -f "$copy/.env" "$work/docker-calls.log" "$work/docker-env.log"
  set +e
  out="$(env -i PATH="$work/bin:$PATH" HOME="$HOME" ${LAUNCH_ENV[@]+"${LAUNCH_ENV[@]}"} \
    bash "$copy/run-itree.sh" "$@" 2>&1)"
  rc=$?
  set -e
}

no_secret_in_output() {
  case "$out" in
    *"$dummy_pw"* | *"$dummy_admin_pw"*) return 1 ;;
  esac
  return 0
}

only_safe_docker_calls() {
  [ ! -f "$work/docker-calls.log" ] && return 0
  ! grep -Ev '^compose version|(^| )config( |$)' "$work/docker-calls.log" >/dev/null
}

expect_refusal() {
  # expect_refusal NAME PATTERN ARGS...
  local name="$1" pattern="$2"
  shift 2
  run_launcher "$@"
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q -- "$pattern" \
    && [ ! -f "$copy/.env" ] && only_safe_docker_calls && no_secret_in_output; then
    ok "$name (exit $rc: $(printf '%s\n' "$out" | grep -m1 -- "$pattern"))"
  else
    ko "$name (exit $rc)"
    printf '%s\n' "$out" | sed 's/^/      /'
  fi
}

# compose_json: resolved compose config for the rendered .env, as JSON
compose_json() {
  local files=(-f "$copy/docker/docker-compose.yml")
  if grep -q "^INVENTREE_PROXY_TLS='owner'" "$copy/.env"; then
    files+=(-f "$copy/docker/docker-compose.tls-owner.yml")
  fi
  env -i PATH="$PATH" HOME="$HOME" "$real_docker" compose --env-file "$copy/.env" \
    "${files[@]}" config --format json
}

published_ports() {
  # print "host_ip:published->target" for each published port
  python3 -I -c '
import json, sys
cfg = json.load(sys.stdin)
for name, svc in sorted(cfg["services"].items()):
    for p in svc.get("ports", []):
        print("%s %s:%s->%s" % (name, p.get("host_ip", "*"), p.get("published"), p.get("target")))
'
}

echo "== Refusals (launcher: up) =="
LAUNCH_ENV=()
write_local
expect_refusal "missing .env.local (template placeholder)" "is still a placeholder" up

write_local "INVENTREE_DB_PASSWORD=__CHANGE_ME__"
expect_refusal "placeholder password" "INVENTREE_DB_PASSWORD is still a placeholder" up

write_local "INVENTREE_DB_PASSWORD=inventree"
expect_refusal "password 'inventree'" "INVENTREE_DB_PASSWORD equals a well-known default" up

write_local "INVENTREE_DB_PASSWORD=Short-dummy-15c"
expect_refusal "password shorter than 16 characters" "INVENTREE_DB_PASSWORD is shorter than 16 characters" up

write_local "INVENTREE_DB_PASSWORD=$dummy_pw" "INVENTREE_BIND_ADDR=0.0.0.0" \
  "INVENTREE_SITE_URL=http://inventree.lan:8080"
expect_refusal "non-loopback bind with http:// site URL" "is not loopback but INVENTREE_SITE_URL uses http://" up

write_local "INVENTREE_DB_PASSWORD=$dummy_pw" "INVENTREE_BIND_ADDR=192.168.50.10" \
  "INVENTREE_SITE_URL=http://192.168.50.10:8080"
expect_refusal "LAN bind with http:// site URL" "is not loopback but INVENTREE_SITE_URL uses http://" up

write_local "INVENTREE_DB_PASSWORD=$dummy_pw"
LAUNCH_ENV=(INVENTREE_DB_PASSWORD=inventree)
expect_refusal "weak password from the environment overrides .env.local" "equals a well-known default" up
LAUNCH_ENV=()

write_local "INVENTREE_DB_PASSWORD=dummy\$with-dollar-sign"
expect_refusal "password with forbidden character" "contains a forbidden character" up

write_local "INVENTREE_DB_PASSWORD=$dummy_pw" "INVENTREE_ADMIN_USER=admin" \
  "INVENTREE_ADMIN_EMAIL=admin@example.invalid" "INVENTREE_ADMIN_PASSWORD=admin"
expect_refusal "weak admin password" "INVENTREE_ADMIN_PASSWORD equals a well-known default" up

write_local "INVENTREE_DB_PASSWORD=$dummy_pw" "INVENTREE_SITE_URL=https://localhost:443"
expect_refusal "site URL port differs from INVENTREE_HTTPS_PORT" "must equal INVENTREE_HTTPS_PORT" up

write_local "INVENTREE_DB_PASSWORD=$dummy_pw" "INVENTREE_SITE_URL=https://inventree.lan:8443/inventree"
expect_refusal "site URL with a path" "INVENTREE_SITE_URL must look like" up

write_local "INVENTREE_DB_PASSWORD=$dummy_pw" "INVENTREE_TLS_MODE=none"
expect_refusal "https:// site URL without a certificate mode" "INVENTREE_TLS_MODE must be" up

if [ "$have_openssl" = true ]; then
  mkdir -p "$copy/certs"
  cp "$tls_dir/cert.pem" "$tls_dir/key.pem" "$copy/certs/"
  chmod 600 "$copy/certs/key.pem"
  write_local "INVENTREE_DB_PASSWORD=$dummy_pw" "INVENTREE_SITE_URL=https://inventree.lan:8443" \
    "INVENTREE_TLS_MODE=owner" "INVENTREE_TLS_CERT_FILE=$copy/certs/cert.pem" \
    "INVENTREE_TLS_KEY_FILE=$copy/certs/key.pem"
  expect_refusal "owner certificate inside the repository" "must live outside the repository" up
  rm -rf "$copy/certs"

  write_local "INVENTREE_DB_PASSWORD=$dummy_pw" "INVENTREE_SITE_URL=https://other.lan:8443" \
    "INVENTREE_TLS_MODE=owner" "INVENTREE_TLS_CERT_FILE=$tls_dir/cert.pem" \
    "INVENTREE_TLS_KEY_FILE=$tls_dir/key.pem"
  expect_refusal "owner certificate for another host" "does not cover 'other.lan'" up
fi

write_local "INVENTREE_DB_PASSWORD=$dummy_pw"
expect_refusal "unknown command does not start the stack" "Unknown command: upp" upp

echo
echo "== Accepted configurations (launcher: check, docker compose config) =="
if [ "$have_compose" != true ]; then
  echo "SKIP  docker compose not available"
else
  # Default: loopback, internal CA
  write_local "INVENTREE_DB_PASSWORD=$dummy_pw"
  run_launcher check
  if [ "$rc" -eq 0 ] && only_safe_docker_calls && no_secret_in_output; then
    ok "default config passes check; output contains no secret"
  else
    ko "default config check (exit $rc)"
    printf '%s\n' "$out" | sed 's/^/      /'
  fi
  perms="$(stat -c %a "$copy/.env" 2>/dev/null || stat -f %Lp "$copy/.env")"
  if [ "$perms" = 600 ]; then ok "runtime .env has mode 600"; else ko "runtime .env mode is $perms"; fi
  ports="$(compose_json | published_ports)"
  printf '%s\n' "$ports" | sed 's/^/      /'
  if [ "$(printf '%s\n' "$ports" | wc -l)" -eq 2 ] \
    && printf '%s\n' "$ports" | grep -q "^$ITREE_CT_PROXY 127.0.0.1:8080->8080\$" \
    && printf '%s\n' "$ports" | grep -q "^$ITREE_CT_PROXY 127.0.0.1:8443->8443\$"; then
    ok "default publishes only the proxy, on 127.0.0.1"
  else
    ko "default published ports"
  fi
  name="$(compose_json | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["name"])')"
  if [ "$name" = docker ]; then ok "compose project name stays 'docker'"; else ko "compose project name is '$name'"; fi
  proxy_env="$(compose_json | python3 -I -c 'import json,sys; print(" ".join(sorted(json.load(sys.stdin)["services"][sys.argv[1]]["environment"])))' "$ITREE_CT_PROXY")"
  cache_env="$(compose_json | python3 -I -c 'import json,sys; print(" ".join(sorted((json.load(sys.stdin)["services"][sys.argv[1]].get("environment") or {}))))' "$ITREE_CT_CACHE")"
  case "$proxy_env $cache_env" in
    *PASSWORD*) ko "proxy or cache receives a password variable" ;;
    *) ok "proxy and cache receive no credentials (proxy env: $proxy_env)" ;;
  esac
  images="$(compose_json | python3 -I -c 'import json,sys; [print(s["image"]) for s in json.load(sys.stdin)["services"].values()]' | sort -u)"
  printf '%s\n' "$images" | sed 's/^/      /'
  if ! printf '%s\n' "$images" | grep -vq '@sha256:[0-9a-f]\{64\}$'; then
    ok "every image is pinned by tag and digest"
  else
    ko "unpinned image found"
  fi

  # LAN exposure over HTTPS with the internal CA
  write_local "INVENTREE_DB_PASSWORD=$dummy_pw" "INVENTREE_BIND_ADDR=192.168.50.10" \
    "INVENTREE_SITE_URL=https://inventree.lan:8443"
  run_launcher check
  ports="$(compose_json | published_ports)"
  if [ "$rc" -eq 0 ] && printf '%s\n' "$ports" | grep -q "^$ITREE_CT_PROXY 192.168.50.10:8443->8443\$" \
    && printf '%s\n' "$ports" | grep -q "^$ITREE_CT_PROXY 127.0.0.1:8080->8080\$" \
    && [ "$(printf '%s\n' "$ports" | wc -l)" -eq 2 ]; then
    ok "LAN + https: HTTPS on 192.168.50.10:8443, HTTP stays on 127.0.0.1"
  else
    ko "LAN + https (exit $rc)"
    printf '%s\n%s\n' "$out" "$ports" | sed 's/^/      /'
  fi
  for kv in "INVENTREE_ALLOWED_HOSTS='inventree.lan,127.0.0.1'" \
    "INVENTREE_TRUSTED_ORIGINS='https://inventree.lan:8443'" \
    "INVENTREE_SESSION_COOKIE_SECURE='True'" "INVENTREE_PROXY_TLS='internal'"; do
    if grep -qx "$kv" "$copy/.env"; then ok "runtime .env sets $kv"; else ko "runtime .env lacks $kv"; fi
  done

  # A stray exported variable cannot change the validated bind address
  write_local "INVENTREE_DB_PASSWORD=$dummy_pw"
  LAUNCH_ENV=(INVENTREE_BIND_ADDR=0.0.0.0 INVENTREE_SITE_URL=http://inventree.lan:8080)
  run_launcher check
  LAUNCH_ENV=()
  if [ "$rc" -eq 0 ] && ! printf '%s\n' "$out" | grep -q '0.0.0.0' \
    && ! grep -q 'INVENTREE_BIND_ADDR=0.0.0.0' "$work/docker-env.log"; then
    ok "exported INVENTREE_BIND_ADDR/SITE_URL are ignored and unset for compose ($(sort -u "$work/docker-env.log" | tr '\n' ' '))"
  else
    ko "exported variables leaked into the configuration"
  fi

  # --dev forces loopback even when .env.local asks for 0.0.0.0
  write_local "INVENTREE_DB_PASSWORD=__CHANGE_ME__" "INVENTREE_BIND_ADDR=0.0.0.0" \
    "INVENTREE_SITE_URL=https://inventree.lan:8443"
  run_launcher check --dev
  ports="$(compose_json | published_ports)"
  printf '%s\n' "$out" | grep -E 'WARNING|Site URL|bind' | sed 's/^/      /'
  printf '%s\n' "$ports" | sed 's/^/      /'
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'DEVELOPMENT MODE' \
    && ! printf '%s\n' "$ports" | grep -vq ' 127\.0\.0\.1:'; then
    ok "--dev binds every published port to 127.0.0.1 and prints a warning"
  else
    ko "--dev binding (exit $rc)"
  fi
  if grep -qx "INVENTREE_SITE_URL='http://localhost:8080'" "$copy/.env"; then
    ok "--dev replaces a non-loopback site URL with http://localhost:8080"
  else
    ko "--dev site URL"
  fi

  if [ "$have_openssl" = true ]; then
    write_local "INVENTREE_DB_PASSWORD=$dummy_pw" "INVENTREE_BIND_ADDR=0.0.0.0" \
      "INVENTREE_SITE_URL=https://inventree.lan:8443" "INVENTREE_TLS_MODE=owner" \
      "INVENTREE_TLS_CERT_FILE=$tls_dir/cert.pem" "INVENTREE_TLS_KEY_FILE=$tls_dir/key.pem"
    run_launcher check
    mounts="$(compose_json | python3 -I -c '
import json, sys
for v in json.load(sys.stdin)["services"][sys.argv[1]]["volumes"]:
    if v["target"].startswith("/etc/caddy/tls/"):
        print(v["source"], "->", v["target"], "read_only=%s" % v.get("read_only", False))
' "$ITREE_CT_PROXY")"
    printf '%s\n' "$mounts" | sed 's/^/      /'
    if [ "$rc" -eq 0 ] && [ "$(printf '%s\n' "$mounts" | grep -c 'read_only=True')" -eq 2 ]; then
      ok "owner TLS mode mounts certificate and key read-only from outside the repository"
    else
      ko "owner TLS mode (exit $rc)"
      printf '%s\n' "$out" | sed 's/^/      /'
    fi
  fi
fi

echo
echo "== Repository checks =="
# Vendored Caddyfile: removing the marked local blocks restores upstream exactly
stripped="$(awk '/# vl-itree: begin/ { skip = 1 } !skip { print } /# vl-itree: end/ { skip = 0 }' \
  "$repo_root/docker/Caddyfile")"
upstream_sha="$ITREE_CADDYFILE_UPSTREAM_SHA256"
got_sha="$(printf '%s\n' "$stripped" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)"
if [ "$got_sha" = "$upstream_sha" ]; then
  ok "docker/Caddyfile minus vl-itree blocks equals upstream $ITREE_CADDYFILE_UPSTREAM_TAG (sha256 $upstream_sha)"
else
  ko "docker/Caddyfile differs from upstream outside marked blocks ($got_sha)"
fi

nonascii="$(cd "$repo_root" || exit 1; LC_ALL=C grep -rlI '[^ -~	]' -- README.md docs run-itree.sh run-itree-dump.sh lib docker tests .env.local.example .gitignore || true)"
if [ -z "$nonascii" ]; then ok "all repository files are ASCII"; else ko "non-ASCII content in: $nonascii"; fi

# Constants live in lib/itree-config.sh only: no container name, in-container
# path or volume directory may appear as a literal in executable script lines.
literals="$(cd "$repo_root" || exit 1
  grep -nE 'inventree-(db|server|worker|proxy|cache)|/var/lib/postgresql|/data/caddy|inventree-(volume|dump)|docker-images|\.env\.local\.pending' \
    run-itree.sh run-itree-dump.sh lib/itree-common.sh | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
if [ -z "$literals" ]; then
  ok "scripts take names and paths from lib/itree-config.sh (no hardcoded literals)"
else
  ko "hardcoded constants outside lib/itree-config.sh:"
  printf '%s\n' "$literals" | sed 's/^/      /'
fi

# Documentation links: every relative link and #anchor in README.md and docs/
# must resolve (GitHub heading anchors).
broken="$(python3 -I - "$repo_root" <<'PYLINKS'
import os, re, sys
root = sys.argv[1]
files = [os.path.join(root, "README.md")]
docs = os.path.join(root, "docs")
files += sorted(os.path.join(docs, f) for f in os.listdir(docs) if f.endswith(".md"))
def anchors(path):
    out, fence = set(), False
    for line in open(path, encoding="ascii"):
        if line.startswith("```"):
            fence = not fence
        elif not fence and re.match(r"#{1,6} ", line):
            title = line.lstrip("#").strip().lower()
            out.add(re.sub(r"[^\w\- ]", "", title).replace(" ", "-"))
    return out
bad = []
for f in files:
    text = re.sub(r"```.*?```", "", open(f, encoding="ascii").read(), flags=re.S)
    for target in re.findall(r"\]\(([^)\s]+)\)", text):
        if re.match(r"[a-z]+://", target):
            continue
        path, _, frag = target.partition("#")
        dest = os.path.normpath(os.path.join(os.path.dirname(f), path)) if path else f
        rel = os.path.relpath(f, root)
        if not os.path.exists(dest):
            bad.append("%s: missing file %s" % (rel, target))
        elif frag and dest.endswith(".md") and frag not in anchors(dest):
            bad.append("%s: missing anchor %s" % (rel, target))
print("\n".join(bad))
PYLINKS
)"
if [ -z "$broken" ]; then
  ok "README.md and docs/*.md: every relative link and anchor resolves"
else
  ko "broken documentation links:"
  printf '%s\n' "$broken" | sed 's/^/      /'
fi

echo
printf 'Result: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

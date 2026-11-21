## InvenTree Stack (Docker)

Run, secure, back up, restore and upgrade the vl-itree InvenTree deployment:
InvenTree, PostgreSQL, Redis and a Caddy reverse proxy that terminates TLS,
started by `run-itree.sh` with Docker Compose.

### Prerequisites
- Docker and Docker Compose v2.20 or newer (`docker compose`).
- `openssl` (optional; used to check owner-supplied certificates and print
  fingerprints).

### Quick start (new instance)

```bash
cp .env.local.example .env.local && chmod 600 .env.local
# set INVENTREE_DB_PASSWORD (16+ characters, not a default)
bash run-itree.sh check      # validate; starts nothing
bash run-itree.sh up         # https://localhost:8443, internal CA
bash run-itree.sh export-ca  # root certificate for clients
```
By default everything listens on `127.0.0.1` only. To serve other machines,
see [docs/network-tls.md](docs/network-tls.md). For the **existing**
instance, follow the
[one-time migration](docs/upgrade.md#one-time-migration-of-the-existing-instance)
instead.

### Commands

```bash
bash run-itree.sh up                 # validate, then start or update (default)
bash run-itree.sh check              # validate and run "docker compose config"; starts nothing
bash run-itree.sh down               # stop and remove containers; deletes .env, keeps .env.local
bash run-itree.sh rotate-db-password # new random DB password
bash run-itree.sh export-ca [FILE]   # export the internal CA root (TLS mode internal)
bash run-itree.sh version            # pinned images and deployed InvenTree version
bash run-itree.sh up --dev           # development start (loopback only, no password checks)
bash run-itree-dump.sh [--offline] [--no-restart]   # backup
```

### Documentation

| Document | Contents |
| --- | --- |
| [docs/configuration.md](docs/configuration.md) | Files, how the runtime `.env` is built, commands, development mode, **script constants** (`lib/itree-config.sh`), troubleshooting |
| [docs/secrets.md](docs/secrets.md) | Where secrets live, password policy, database password rotation |
| [docs/network-tls.md](docs/network-tls.md) | Published ports, remote access over HTTPS, certificate modes `internal` and `owner`, client trust |
| [docs/backup-restore.md](docs/backup-restore.md) | Backup contents (database, secret key, configuration, assets) and the restore procedure |
| [docs/upgrade.md](docs/upgrade.md) | Upgrade procedure, PostgreSQL major policy, release notes 1.0.7 to 1.7.3, one-time migration of the existing instance |
| [docs/kn-api-user.md](docs/kn-api-user.md) | Admin access to the web UI, read-only `kn-exchange` user and API token |
| [docs/testing.md](docs/testing.md) | Offline test suite, static checks, rules for integration tests |

### Pinned images

All images are pinned by tag and digest in `docker/versions.env`, the single
source of truth. The launcher copies them into the runtime `.env`;
`.env.local` cannot override them. Keep this table in sync when upgrading
([docs/upgrade.md](docs/upgrade.md)).

| Service | Image | Tag | Digest |
| --- | --- | --- | --- |
| server, worker | `inventree/inventree` | `1.7.3` | `sha256:bd58a1d1891dac39a19b5c40a7fa6bd9fc4d6752ae0bd69da4582a4afce5dfb7` |
| database | `postgres` | `17.12` | `sha256:b60e90042aa6b8dbecd58e224b3e36114dbf8ad754465264c2476ad58a86e45c` |
| cache | `redis` | `7.4.12-alpine` | `sha256:7f7d30b7fdd09467bac58198a1f166dd69789d348d4fe859cccb20e0cf287fbe` |
| proxy | `caddy` | `2.11.9-alpine` | `sha256:003a97808e781aa9f7e75cc2f43d34d461099031faf5e20faefb9f61126836f0` |

Digests are multi-arch index digests, checked on 2026-11-21 against Docker Hub
and `registry-1.docker.io`. When the pin was set, `inventree/inventree:1.7.3`
had the same digest as `stable`, `postgres:17.12` matched `postgres:17`, and
the other two matched the official recipe's `redis:7-alpine` and
`caddy:alpine`. Show the pins and the deployed version with
`bash run-itree.sh version`.

### Tests

```bash
bash tests/test-launcher.sh   # offline; starts no containers
```
Details: [docs/testing.md](docs/testing.md).

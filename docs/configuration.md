# Configuration

How the vl-itree scripts are configured: which file holds what, how the
runtime `.env` is built, development mode, and the shared script constants.

Back to the [README](../README.md).

## Files

| Path | Tracked | Purpose |
| --- | --- | --- |
| `run-itree.sh` | yes | Launcher: `up`, `check`, `down`, `rotate-db-password`, `export-ca`, `version` |
| `run-itree-dump.sh` | yes | Backup ([backup-restore.md](backup-restore.md)) |
| `lib/itree-config.sh` | yes | **All script constants** (see [Script constants](#script-constants)) |
| `lib/itree-common.sh` | yes | Shared shell functions; loads `lib/itree-config.sh` |
| `docker/docker-compose.yml` | yes | Compose recipe (based on official 1.7.3, hardened) |
| `docker/docker-compose.tls-owner.yml` | yes | Overlay that mounts an owner certificate read-only |
| `docker/Caddyfile` | yes | Official 1.7.3 Caddyfile with marked local TLS and redirect changes |
| `docker/env.template` | yes | Deployment defaults (no secrets) and placeholders |
| `docker/versions.env` | yes | Pinned images (tag and digest) |
| `.env.local.example` | yes | Example of the local secrets file |
| `.env.local` | **no** | Owner secrets and overrides (mode 600). Never overwritten or deleted by the scripts, except the password line changed by `rotate-db-password`. |
| `.env` | no | Runtime file generated on every start (mode 600); removed by `down` |
| `inventree-volume/` | no | Persistent data |
| `inventree-dump/` | no | Backups |
| `docker-images/` | no | Optional image tarball cache |
| `docs/` | yes | This documentation |
| `tests/test-launcher.sh` | yes | Offline tests ([testing.md](testing.md)) |

## Where a value lives

| Kind of value | File | Who changes it |
| --- | --- | --- |
| Script constants: file locations, container names, in-container paths, backup contents, password policy | `lib/itree-config.sh` | maintainer |
| Deployment defaults: ports, bind address, site URL, TLS mode, InvenTree settings | `docker/env.template` | maintainer (defaults); the owner overrides them in `.env.local` |
| Secrets and local overrides | `.env.local` | owner |
| Image tags and digests | `docker/versions.env` | maintainer, during an [upgrade](upgrade.md) |

## Runtime `.env`

The launcher builds the runtime `.env` from these sources, later ones winning:

1. `docker/env.template`, the defaults;
2. `.env.local`, the owner's secrets and overrides. It is parsed as
   `KEY=VALUE` text and never run as shell code;
3. the process environment, for credential keys only (`ITREE_ENV_KEYS`):
   `INVENTREE_DB_PASSWORD`, `INVENTREE_ADMIN_USER`, `INVENTREE_ADMIN_EMAIL`,
   `INVENTREE_ADMIN_PASSWORD`;
4. `docker/versions.env`;
5. computed values: the data path, TLS mode, `INVENTREE_ALLOWED_HOSTS`,
   `INVENTREE_TRUSTED_ORIGINS` and `INVENTREE_SESSION_COOKIE_SECURE`.

`.env.local` cannot set pinned keys (`ITREE_PINNED_KEYS`), computed keys
(`ITREE_COMPUTED_KEYS`) or `COMPOSE_PROJECT_NAME` (`ITREE_TEMPLATE_ONLY_KEYS`).
Such lines are ignored with a warning.

Before calling `docker compose`, the launcher unsets every key it rendered
from the environment. A variable exported in your shell therefore cannot
override a validated value: Compose would otherwise prefer the shell value
to the one in `.env`.

`.env.local` format: `KEY=VALUE`, one per line, no shell expansion. An
optional `export ` prefix and one pair of surrounding quotes are accepted.
Error messages show the file name and line number, never the line itself.

Create the local file once:
```bash
cp .env.local.example .env.local
chmod 600 .env.local
# edit INVENTREE_DB_PASSWORD (new instance) and the network settings
```
Password rules and rotation: [secrets.md](secrets.md). Network and
certificate settings: [network-tls.md](network-tls.md).

## Commands

| Command | Effect |
| --- | --- |
| `bash run-itree.sh up` | Validate, then start or update the stack (default; aliases `start`, `run`) |
| `bash run-itree.sh check` | Validate and run `docker compose config`; starts nothing |
| `bash run-itree.sh down` | Stop and remove the containers (aliases `stop`, `shutdown`); deletes `.env`, keeps `.env.local` |
| `bash run-itree.sh rotate-db-password` | New random database password ([secrets.md](secrets.md#database-password-rotation)) |
| `bash run-itree.sh export-ca [FILE]` | Export the internal CA root ([network-tls.md](network-tls.md#certificate-mode-internal)) |
| `bash run-itree.sh version` | Pinned images and the deployed InvenTree version |
| `bash run-itree-dump.sh [--offline] [--no-restart]` | Backup ([backup-restore.md](backup-restore.md)) |

`up` creates the data directories (`ITREE_VOLUME_DIRS`) under
`inventree-volume/`. It loads pinned images from `docker-images/` if they are
cached there, otherwise it pulls them by digest and caches them. Then it
starts the stack. Unknown commands are rejected; they never fall through to
`up`.

## Development mode

`up --dev` and `check --dev` skip the password checks and print a warning.
They force `INVENTREE_BIND_ADDR` to `127.0.0.1` (`ITREE_LOOPBACK_ADDR`), and
replace a non-loopback `INVENTREE_SITE_URL` with
`http://localhost:<INVENTREE_HTTP_PORT>`. They use the same
`inventree-volume/`. Never use `--dev` for the working instance.

## Script constants

Every fixed value the scripts use is assigned in `lib/itree-config.sh`, and
only there. `lib/itree-common.sh` loads it, so `run-itree.sh` and
`run-itree-dump.sh` get it through that file; `tests/test-launcher.sh`
sources it directly. The file only assigns variables. It needs
`project_root` (the repository path) to be set first. A test fails if a
container name or in-container path appears as a literal in the scripts.

Values marked **sync** are also written literally in
`docker/docker-compose.yml` or `docker/Caddyfile`; change both together.

| Group | Constants | Notes |
| --- | --- | --- |
| Requirements | `ITREE_MIN_COMPOSE_VERSION` | Oldest Compose with health-gated `depends_on` and `--wait` |
| Tracked files | `ITREE_DOCKER_DIR`, `ITREE_COMPOSE_FILE`, `ITREE_COMPOSE_TLS_OWNER_FILE`, `ITREE_TEMPLATE_FILE`, `ITREE_VERSIONS_FILE`, `ITREE_CADDYFILE`, `ITREE_LOCAL_EXAMPLE_FILE` | Paths under the repository |
| Vendored Caddyfile | `ITREE_CADDYFILE_UPSTREAM_TAG`, `ITREE_CADDYFILE_UPSTREAM_SHA256` | Upstream tag and hash checked by the tests; update both when re-vendoring |
| Local files | `ITREE_LOCAL_FILE`, `ITREE_LOCAL_PENDING_FILE`, `ITREE_ENV_FILE` (**sync**: `env_file: ../.env`) | `.env.local`, `.env.local.pending`, `.env` |
| Data and caches | `ITREE_VOLUME_ROOT`, `ITREE_PGDATA_DIR` (**sync**: `PGDATA`), `ITREE_VOLUME_DIRS` (**sync**: volume mounts), `ITREE_DUMP_ROOT`, `ITREE_IMAGES_CACHE_DIR`, `ITREE_CA_EXPORT_FILE` | `inventree-volume/`, `inventree-dump/`, `docker-images/`, `inventree-root-ca.crt` |
| Containers | `ITREE_CT_DB`, `ITREE_CT_CACHE`, `ITREE_CT_SERVER`, `ITREE_CT_WORKER`, `ITREE_CT_PROXY` (**sync**: `container_name` and service names) | `inventree-db`, ... |
| In-container paths | `ITREE_DB_DATA_DIR` (**sync**: database volume mount), `ITREE_PROXY_CA_ROOT` | Data volume in the database container; Caddy's internal CA root |
| Images | `ITREE_IMAGE_TABLE` (**sync**: `image:` lines), `ITREE_LEGACY_INVENTREE_IMAGE`, `ITREE_IMAGE_VERSION_LABEL` | Prefix-to-repository table; tags and digests are in `docker/versions.env` |
| Configuration keys | `ITREE_ENV_KEYS`, `ITREE_PINNED_KEYS`, `ITREE_COMPUTED_KEYS`, `ITREE_TEMPLATE_ONLY_KEYS` | See [Runtime `.env`](#runtime-env) |
| Network | `ITREE_LOOPBACK_ADDR` (**sync**: HTTP port binding) | Forced `--dev` bind address; health-check host |
| Password policy | `ITREE_MIN_SECRET_LENGTH`, `ITREE_PLACEHOLDER`, `ITREE_KNOWN_DEFAULTS`, `ITREE_GENERATED_PASSWORD_BYTES` | See [secrets.md](secrets.md) |
| Backups | `ITREE_DUMP_TIMESTAMP_FORMAT`, `ITREE_DUMP_DB_FILE`, `ITREE_DUMP_KEYS_FILE`, `ITREE_DUMP_ASSETS_FILE`, `ITREE_DUMP_METADATA_FILE`, `ITREE_DUMP_CHECKSUM_FILE`, `ITREE_BACKUP_REQUIRED_KEYS`, `ITREE_BACKUP_OPTIONAL_KEYS`, `ITREE_BACKUP_ASSET_DIRS`, `ITREE_BACKUP_STOP_QUIESCED`, `ITREE_BACKUP_STOP_OFFLINE` | See [backup-restore.md](backup-restore.md) |

To change a constant: edit `lib/itree-config.sh`, update any **sync**
location, then run the [tests](testing.md).

## Troubleshooting

- **The database never becomes healthy on a fresh install.** If `up` runs
  with a restrictive umask such as `077`, `inventree-volume/` is created
  with mode 700, and PostgreSQL inside its container (a different user)
  cannot create `pgdb/`. Create the directory with a normal umask
  (`umask 022`) before the first `up`, or run
  `chmod 755 inventree-volume` once. This is not needed for existing
  instances.
- **A setting from your shell has no effect.** Only the credential keys are
  read from the environment (see [Runtime `.env`](#runtime-env)); put other
  settings in `.env.local`.

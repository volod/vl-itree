# Backup and restore

What a backup contains, how to take one, and how to restore it, including
the secret key and configuration files.

Back to the [README](../README.md).

## Backup

```bash
bash run-itree-dump.sh                         # stop server+worker, dump, start again
bash run-itree-dump.sh --offline               # stop everything except the database
bash run-itree-dump.sh --offline --no-restart  # ... and leave it stopped (before an upgrade)
```
The output goes to `inventree-dump/<timestamp>/` (directory mode 700, files
mode 600). File names and contents are defined in `lib/itree-config.sh`
(`ITREE_DUMP_*`, `ITREE_BACKUP_*`).

| File | Contents |
| --- | --- |
| `db.dump` | `pg_dump -Fc` of the InvenTree database |
| `keys.tar.gz` | **Secret.** `secret_key.txt`, `config.yaml`, `oidc.pem`, `plugins.txt` (if present), `caddy/data/` (internal CA) |
| `assets.tar.gz` | `media/`, `static/`, `plugins/`, legacy `config/` (those present) |
| `metadata.txt` | Timestamp, mode, deployed and pinned images, PostgreSQL version, database name and user. No secrets. |
| `SHA256SUMS` | Checksums of the files above |

Since InvenTree 1.6.0, API tokens are stored as an HMAC peppered with the
Django secret key. A restore without `secret_key.txt` invalidates every API
token. `oidc.pem` signs OAuth2/OIDC tokens; the OAuth2 provider is on by
default since 1.6.0. The backup therefore fails if `secret_key.txt` or
`config.yaml` is missing.

How the backup works:
- The database is read inside its container over the local socket, so no
  password is passed or stored.
- Data-directory files are read inside the database container, because
  InvenTree creates them as root.
- If the database container is not running, it is started for the dump and
  stopped again afterwards.
- On any error, the stopped services are started again and the partial
  directory is renamed to `<timestamp>.incomplete`.
- `--offline` keeps the database running, because `pg_dump` needs it, but
  nothing else can reach the database.

Copy finished backups to offline storage and protect them like passwords.

## Restore

Restore with the same InvenTree version that made the backup; `metadata.txt`
records it. Check out the vl-itree commit or tag that pins that version,
then:

```bash
# 1. Stop the stack and keep the current data aside (do not delete it yet)
bash run-itree.sh down
mv inventree-volume inventree-volume.before-restore

# 2. Restore keys/configuration and assets into a fresh data directory
D=inventree-dump/<timestamp>
(cd "$D" && sha256sum -c SHA256SUMS)
mkdir inventree-volume
tar -C inventree-volume -xzf "$D/keys.tar.gz"     # secret_key.txt, config.yaml, oidc.pem, caddy/data
tar -C inventree-volume -xzf "$D/assets.tar.gz"   # media, static, plugins

# 3. Start only the database. A fresh data directory adopts the password in
#    .env.local. Run this in a shell without exported INVENTREE_* variables.
bash run-itree.sh check
docker compose --env-file .env -f docker/docker-compose.yml up -d --no-deps --wait inventree-db

# 4. Load the dump into the empty database
docker exec -i inventree-db pg_restore -U inventree -d inventree --no-owner --exit-on-error < "$D/db.dump"

# 5. Start everything and verify; existing API tokens must still work
bash run-itree.sh up
```
For the verification in step 5, see [upgrade.md](upgrade.md#upgrade-procedure),
step 4. Delete `inventree-volume.before-restore` only after the checks pass.
Its `pgdb/` is owned by the container's postgres user; remove it with `sudo`
or from a container.

If the new `inventree-volume/` was created with a restrictive umask, see
[configuration.md](configuration.md#troubleshooting).

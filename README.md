## InvenTree Stack (Docker)

Instructions to run, stop, dump, and work with data.

### Prerequisites
- Docker and Docker Compose v2 (`docker compose`) installed.

### Start (run)
```bash
bash run-itree.sh
```
- Generates `.env` from an embedded template
- Creates data directories under `inventree-volume/`
- Starts containers and exposes the app at http://localhost:8080

### Stop (shutdown)
```bash
bash run-itree.sh down
```
- Stops containers and removes the runtime `.env` to avoid stale absolute paths next run

### Dump (backup)
Create a consistent backup of the database and application assets into `inventree-dump/<timestamp>/`:
```bash
bash run-itree-dump.sh
```
Offline mode (stops the entire stack during backup):
```bash
bash run-itree-dump.sh --offline
```
Outputs per backup:
- `db.dump`  PostgreSQL custom-format dump (usable with `pg_restore`)
- `assets.tar.gz`  Archive of `inventree-volume/media`, `static`, `config`
- `metadata.txt`  Basic context (timestamp, mode, db connection info)

### Working with Data
- Persistent data lives in `inventree-volume/`:
  - `media/` user-uploaded files
  - `static/` collected static assets
  - `config/` proxy configuration (e.g., `Caddyfile`)
  - `pgdb/` PostgreSQL data directory (owned by the DB container)

- Database restore (example):
  1) Ensure the stack is running (or use `--offline` then restore before bringing it back):
  ```bash
  bash run-itree.sh
  ```
  2) Restore into the running DB container using `pg_restore`:
  ```bash
  docker exec -i inventree-db bash -lc "PGPASSWORD=$INVENTREE_DB_PASSWORD pg_restore -h $INVENTREE_DB_HOST -p $INVENTREE_DB_PORT -U $INVENTREE_DB_USER -d $INVENTREE_DB_NAME -c" < inventree-dump/<timestamp>/db.dump
  ```

- Assets restore (example):
```bash
tar -C inventree-volume -xzf inventree-dump/<timestamp>/assets.tar.gz
```

Notes:
- The dump script stops app containers during backup to avoid writes; the DB remains online by default for minimal downtime.
- Use `--offline` for the strongest consistency if you prefer a brief full outage.

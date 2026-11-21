# Secrets and the database password

Password rules, where secrets live, and how to rotate the PostgreSQL password
of an existing instance.

Back to the [README](../README.md). Related: [configuration.md](configuration.md).

## Where secrets live

- `.env.local` (untracked, mode 600) holds the database password and the
  optional admin bootstrap credentials. Credential keys may come from the
  process environment instead
  ([configuration.md](configuration.md#runtime-env)).
- The runtime `.env` (mode 600) is generated from them on every start and
  removed by `down`.
- `docker/env.template` holds only the placeholder `__CHANGE_ME__`
  (`ITREE_PLACEHOLDER`).
- Backups contain the Django secret key and private keys
  ([backup-restore.md](backup-restore.md)).

The scripts never print a secret. Error messages name the key, not its value.

## Password policy

Before any container starts, `up` refuses to continue when
`INVENTREE_DB_PASSWORD`, or `INVENTREE_ADMIN_PASSWORD` if set:
- is missing or empty;
- is still a placeholder (`__CHANGE_ME__`);
- equals a well-known default (`ITREE_KNOWN_DEFAULTS`: `inventree`,
  `pgpassword`, `postgres`, `password`, `admin`, ...) or the user name;
- is shorter than 16 characters (`ITREE_MIN_SECRET_LENGTH`);
- contains whitespace, a quote, a backslash, a backtick, `$` or `#`.

`INVENTREE_ADMIN_USER`, `INVENTREE_ADMIN_EMAIL` and `INVENTREE_ADMIN_PASSWORD`
must be set together. `--dev` turns these checks into warnings
([configuration.md](configuration.md#development-mode)). The limits are
defined in `lib/itree-config.sh`.

## Database password rotation

PostgreSQL applies `POSTGRES_PASSWORD` only when it initializes an empty data
directory, so changing `.env.local` alone does not change the password of an
existing instance. Rotate it with:
```bash
bash run-itree.sh rotate-db-password
```
What it does:
1. It refuses to run if `INVENTREE_DB_PASSWORD` is exported in the shell,
   because the export would override `.env.local`, or if a
   `.env.local.pending` file is left from an earlier run.
2. Starts only the database container if it is not running.
3. Generates a random 64-character password (`ITREE_GENERATED_PASSWORD_BYTES`
   bytes as hex) and writes it to `.env.local.pending` (mode 600).
4. Runs `ALTER ROLE` inside the database container over its local socket. The
   password reaches `psql` through the environment, never on a command line,
   and statement logging is disabled for that session.
5. On success it replaces only the `INVENTREE_DB_PASSWORD` line of
   `.env.local`; every other line is kept. On failure it deletes the pending
   file, and the password and `.env.local` stay unchanged.
6. If server and worker run the pinned image, it recreates them with the new
   password. If they run another image (for example the old `stable`
   deployment), it **stops** them instead, because recreating them would
   upgrade without a backup. If only the database was running, it stops the
   database again if it started it.

The password is never printed. The next `up` also recreates the database
container, because its `POSTGRES_PASSWORD` variable changed; the data is not
touched.

For a **new** instance, rotation is not needed: set `INVENTREE_DB_PASSWORD`
in `.env.local` before the first `up`, and PostgreSQL adopts it.

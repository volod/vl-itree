# Upgrade

How to change the pinned InvenTree version safely, the PostgreSQL major
version policy, the release-note items from 1.0.7 to 1.7.3, and the one-time
migration of the existing instance.

Back to the [README](../README.md).

## Upgrade procedure

`INVENTREE_AUTO_UPDATE=True` stays enabled, so migrations run on the first
start after the pinned image changes. Change the pin **only after a fresh
offline backup**:

1. `bash run-itree-dump.sh --offline --no-restart`, then copy the backup off
   the machine ([backup-restore.md](backup-restore.md)).
2. Change `INVENTREE_TAG` and `INVENTREE_DIGEST` in `docker/versions.env`,
   and the [Pinned images](../README.md#pinned-images) table in the README.
   Take the tag from the `inventree/InvenTree` GitHub release (not a
   pre-release), and the digest from Docker Hub for that exact tag. Never use
   `stable` or `latest`. Read the release notes between the two versions,
   and compare `contrib/container/docker-compose.yml` and `Caddyfile` at the
   new tag with `docker/`. If you re-vendor the Caddyfile, update
   `ITREE_CADDYFILE_UPSTREAM_TAG` and `ITREE_CADDYFILE_UPSTREAM_SHA256` in
   `lib/itree-config.sh`.
3. `bash run-itree.sh up`, and let migrations run:
   `docker logs -f inventree-server`. A large jump can take minutes. If `up`
   reports the server unhealthy while migrations are still running, wait for
   them to finish and run `bash run-itree.sh up` again.
4. Confirm the version over the HTTPS URL. `GET /api/` needs no login:
   ```bash
   curl --cacert inventree-root-ca.crt -s https://inventree.lan:8443/api/ | python3 -m json.tool | grep -E '"(version|apiVersion)"'
   ```
   Expect `"version": "1.7.3"` and the matching `apiVersion`. Then log in
   through the web UI and check the owner's usual workflows.
5. Keep the backup until the owner's checks pass. To roll back, restore that
   backup with the previous pin.

## PostgreSQL major upgrade

The PostgreSQL major version stays at 17; the official 1.7.3 recipe also
uses 17. A future major change (for example to 18) cannot reuse the data
directory. It needs a dump with the old major, a fresh data directory with
the new major, and a restore
([backup-restore.md](backup-restore.md#restore), steps 2 to 5). Treat it as
its own change; never bump the major together with an InvenTree upgrade.

## Release notes from 1.0.7 to 1.7.3: manual steps

The deployed version could not be read on the build host (no container or
cached image there). The previous `docker-compose.yml` is identical to the
official recipe of 1.0.7 to 1.1.12, so the deployed image is at least about
1.0.7. Run `bash run-itree.sh version` with the old stack running to confirm.
Items that need action or attention:

- **1.2.0**: PostgreSQL 14 or newer is required. This deployment already uses
  `postgres:17`; no action.
- **1.5.0**: API throttling is on by default (anonymous 20/minute,
  authenticated 60/second). Clients that sync in bulk must handle HTTP 429
  (`Retry-After`), or the owner tunes `INVENTREE_THROTTLE_USER` /
  `INVENTREE_THROTTLE_ANON`.
- **1.5.0**: `invoke migrate` / `invoke update` no longer create migration
  files. This matters only for custom plugins with model changes.
- **1.6.0**: API tokens use the v2 format, stored as an HMAC peppered with the
  secret key. Existing v1 tokens keep working. `GET /api/user/me/token/`
  issues a new token on every call and revokes the previous token with the
  same name. Back up `secret_key.txt` (done by the dump).
- **1.6.0**: The OAuth2/OIDC provider is on by default. It creates `oidc.pem`
  and a default public client (PKCE) at startup. Review it under Admin Center
  > identity federation.
- **1.7.0**: New `pricing` role. A migration grants it to every group that has
  `part` permissions; review groups that should not see prices.
- **1.7.1**: Token issuance endpoints enforce MFA rules. While MFA is
  enforced site-wide, tokens of users without MFA are refused.
- **API breaking changes** in 1.1.0, 1.2.0, 1.3.0, 1.4.0, 1.5.0, 1.6.0 and
  1.7.0: generic status, parameters, tags filters, unified metadata
  endpoints, supplier parts, removal of image download, barcode scan API,
  duplication API, optional field permissions, FSM states, renamed filters,
  notes. Review existing API integrations against the 1.7.3 API schema
  before relying on them.
- **Plugins**: if `INVENTREE_PLUGINS_ENABLED=True` loads custom plugins
  (`plugins.txt`, `plugins/`), check that they support 1.7.x (plugin tables
  moved in 1.3.0; frontend plugin library updated in 1.7.0).
- **Compose recipe** (adopted here): healthchecks with health-gated
  `depends_on` (1.5.3), a Redis `/data` volume with persistence disabled
  (1.2.0/1.5.0), `INVENTREE_WEB_PORT` and `INVENTREE_SERVER` (1.3.0),
  and the X-Forwarded settings.

## One-time migration of the existing instance

The previous scripts served plain HTTP on all interfaces (`0.0.0.0:8080`)
with the database password `inventree`, and regenerated `.env` on every
start. Move to this version in this order:

1. With the old stack still running: `bash run-itree.sh version`, and record
   the deployed version.
2. `bash run-itree-dump.sh --offline --no-restart`. It works against the old
   containers and leaves them stopped. Copy the backup off the machine.
3. `cp .env.local.example .env.local && chmod 600 .env.local`. Set the
   network and TLS settings ([network-tls.md](network-tls.md)), and leave
   `INVENTREE_DB_PASSWORD` as the placeholder.
4. `bash run-itree.sh rotate-db-password`. It sets a strong password in the
   database and in `.env.local` ([secrets.md](secrets.md#database-password-rotation)).
5. `bash run-itree.sh up`. This deploys 1.7.3 and runs migrations. Then
   follow [Upgrade procedure](#upgrade-procedure), steps 4 and 5.
6. In `internal` mode: `bash run-itree.sh export-ca`, and distribute the root
   ([network-tls.md](network-tls.md#client-trust)).
7. Create the KN user ([kn-api-user.md](kn-api-user.md)).

`inventree-volume/config/Caddyfile`, which the old scripts copied, is no
longer used; the backup keeps it in `assets.tar.gz`. Caddy now keeps its state
in `inventree-volume/caddy/{data,config,log}`.

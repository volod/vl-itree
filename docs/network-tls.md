# Network exposure and TLS

Which ports are published, how to serve other machines over HTTPS, the two
certificate modes, and how clients trust the server.

Back to the [README](../README.md).

## Listeners

| Listener | Bound to | Serves |
| --- | --- | --- |
| HTTPS `INVENTREE_HTTPS_PORT` (default 8443) | `INVENTREE_BIND_ADDR` (default `127.0.0.1`) | the site |
| HTTP `INVENTREE_HTTP_PORT` (default 8080) | always `127.0.0.1` | redirect to HTTPS (keeps the HTTPS port); serves the site only when the site URL is `http://` |

No other port is published. The database, cache and the proxy's internal
health endpoint (`:9090`) are reachable only on the Compose network. Caddy
listens on the same port numbers inside its container, so the site address
and redirects carry the right port.

## Serving other machines

Set this in `.env.local`:
```
INVENTREE_BIND_ADDR=192.168.1.20          # LAN address of this host, or 0.0.0.0
INVENTREE_SITE_URL=https://inventree.lan:8443
INVENTREE_TLS_MODE=internal               # or owner
```
The launcher refuses:
- a non-loopback bind address with an `http://` site URL;
- a site URL whose port differs from `INVENTREE_HTTPS_PORT`;
- a site URL with a path.

Clients must connect with the exact host name from `INVENTREE_SITE_URL`.
The certificate and Caddy's routing are issued for that name, so connecting
by IP address fails unless the site URL uses that IP. The name must resolve
to this host on the clients (DNS or `/etc/hosts`).

## Host, origin and cookie settings

`INVENTREE_SITE_URL` drives Caddy's site address. In InvenTree 1.7.3 it also
drives `ALLOWED_HOSTS`, `CSRF_TRUSTED_ORIGINS` and the allowed CORS origins.
The launcher also sets:
- `INVENTREE_ALLOWED_HOSTS=<site host>,127.0.0.1`. The `config.yaml` that
  InvenTree generates allows `*`. `127.0.0.1` (`ITREE_LOOPBACK_ADDR`) is the
  Host of the proxy's internal health check; Caddy routes only the site host,
  so outside requests cannot use it.
- `INVENTREE_TRUSTED_ORIGINS=<site URL>`.
- `INVENTREE_SESSION_COOKIE_SECURE=True` for `https://`.

The template sets `INVENTREE_CORS_ORIGIN_ALLOW_ALL=False`, to override
`cors.allow_all: true` in the generated `config.yaml`, and
`INVENTREE_USE_X_FORWARDED_HOST/PORT/PROTO=True`, so Django sees the HTTPS
URL behind Caddy. Owner values for `INVENTREE_ALLOWED_HOSTS` or
`INVENTREE_TRUSTED_ORIGINS` in `.env.local` are kept as given.

## Certificate mode `internal`

Caddy's internal CA issues the server certificate (`tls internal`). Its state
lives in `inventree-volume/caddy/data/`, which the backup includes. The
root is valid for 10 years; Caddy renews the intermediate and leaf
certificates automatically.

After the first HTTPS start, export the root and note its fingerprint:
```bash
bash run-itree.sh export-ca                 # writes ./inventree-root-ca.crt (gitignored)
```

## Certificate mode `owner`

Supply a PEM certificate chain and its key. Both must be absolute paths
outside the repository:
```
INVENTREE_TLS_MODE=owner
INVENTREE_TLS_CERT_FILE=/etc/vl-itree/tls/fullchain.pem
INVENTREE_TLS_KEY_FILE=/etc/vl-itree/tls/privkey.pem     # chmod 600
```
They are mounted read-only through `docker/docker-compose.tls-owner.yml`.
When `openssl` can read them, the launcher refuses:
- a world-readable key;
- an expired certificate;
- a certificate that does not cover the site host;
- a key that does not match the certificate.

On SELinux hosts, give the files a label the container can read (for
example `chcon -t container_file_t`). After renewing the files, run
`docker restart inventree-proxy`.

## Client trust

This applies to every client, including KN. Clients verify the server
certificate; never disable verification. In `internal` mode, give each
client `inventree-root-ca.crt` over a trusted channel, and compare the
SHA-256 fingerprint with the one `export-ca` printed. In `owner` mode,
clients need the CA that issued the owner certificate.

- Per application: Python `requests`: `verify="/path/inventree-root-ca.crt"`
  or `REQUESTS_CA_BUNDLE=/path/inventree-root-ca.crt`; curl:
  `--cacert /path/inventree-root-ca.crt`; many other tools read
  `SSL_CERT_FILE`.
- System-wide on Debian/Ubuntu:
  `sudo cp inventree-root-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates`.
- macOS:
  `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain inventree-root-ca.crt`.
- Windows: `certutil -addstore -f Root inventree-root-ca.crt`.

If `inventree-volume/caddy/data` is lost and not restored, Caddy creates a new
root and every client has to import it again.

## Vendored Caddyfile

`docker/Caddyfile` is the official InvenTree 1.7.3 Caddyfile. Local changes
sit between `# vl-itree: begin` and `# vl-itree: end` markers:
- listen ports;
- TLS snippets per mode;
- an explicit HTTP->HTTPS redirect. Caddy's automatic redirect drops the
  non-standard HTTPS port, so it is replaced.

Removing the marked blocks gives the upstream file byte for byte. The tests
check this against `ITREE_CADDYFILE_UPSTREAM_SHA256` in
`lib/itree-config.sh`.

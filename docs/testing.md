# Testing

How to check the scripts without touching a real instance.

Back to the [README](../README.md).

## Offline test suite

```bash
bash tests/test-launcher.sh
```
It runs in a throwaway copy of the scripts and `docker/`, with a `docker`
shim on `PATH` that allows only `compose version` and `compose config`. It
starts, stops and pulls no containers, and never reads `inventree-volume/`,
`inventree-dump/` or `.env*` of the checkout. All passwords are dummy values
generated per run. It checks:
- refusals: placeholder, `inventree`, a short password, a forbidden
  character, a weak admin password, a weak password from the environment, a
  non-loopback bind with `http://`, a port mismatch, a URL with a path, a
  missing TLS mode, an owner certificate inside the repository or for
  another host, and unknown commands;
- accepted configurations: only the proxy publishes ports, on the expected
  addresses; every image is pinned by digest; proxy and cache receive no
  credentials; the computed host, origin and cookie settings; exported shell
  variables are ignored; `--dev` binds to loopback; owner TLS mounts are
  read-only;
- repository rules: the vendored Caddyfile matches upstream outside the
  marked blocks; every file is ASCII; no container name or in-container path
  is hardcoded outside `lib/itree-config.sh`.

## Static checks

```bash
for f in run-itree.sh run-itree-dump.sh lib/itree-config.sh lib/itree-common.sh tests/test-launcher.sh; do bash -n "$f"; done
shellcheck -x run-itree.sh run-itree-dump.sh lib/itree-config.sh lib/itree-common.sh tests/test-launcher.sh
```

## Integration checks with containers

Rotation, backup and the full HTTPS stack need real containers. Run them only
in a separate copy of the repository with its own empty `inventree-volume/`,
on a host where no `inventree-*` containers exist. The container names are
fixed, so a test stack would collide with a real one. Never run them against
the working instance's data.

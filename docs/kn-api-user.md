# API user for KN (read-only)

How the owner gets admin access to the InvenTree web UI, creates the
read-only `kn-exchange` user, and issues its API token. No script does this.

Back to the [README](../README.md).

## Admin access

The Admin Center is part of InvenTree's own web UI; there is no separate
program. With the stack running, open the site URL in a browser and log in
with an account that has the **staff** or **superuser** flag. Then open the
Admin Center in either of these ways:
- the user menu in the top-right corner > **Admin Center**;
- the direct URL `<INVENTREE_SITE_URL>/web/settings/admin`, for example
  `https://inventree.lan:8443/web/settings/admin`.

Accounts without these flags never see the Admin Center. If no admin account
exists, or its password is lost, use the host that runs the stack. Shell
access to Docker there already means full control of the instance. Use one
of these:

- **Create a new superuser.** It prompts for name, email and password, and
  the password is not echoed:
  ```bash
  docker exec -it inventree-server invoke superuser
  ```
- **Reset the password of an existing account.** It prompts for the new
  password:
  ```bash
  docker exec -it -w /home/inventree/src/backend/InvenTree inventree-server \
    python manage.py changepassword <username>
  ```
- **Create a superuser on first start.** Set `INVENTREE_ADMIN_USER`,
  `INVENTREE_ADMIN_EMAIL` and `INVENTREE_ADMIN_PASSWORD` in `.env.local`
  (the password is checked like the database password, see
  [secrets.md](secrets.md#password-policy)), then run `bash run-itree.sh up`.
  InvenTree creates the account only if it does not exist. Remove the three
  lines after the first login, so the password does not stay in a file.

Prefer the first two: the password never appears on a command line, in the
shell history or in a file. Use the admin account only for administration.
Turn on MFA for it (user settings > Security); InvenTree recommends MFA for
staff and superuser accounts. KN never uses the admin account.

Reference: [InvenTree 1.7.3 admin documentation](https://github.com/inventree/InvenTree/blob/1.7.3/docs/docs/settings/admin.md).

## Create the KN user and token

1. Web UI > Admin Center > Users / Groups. Create group `kn-read`. Give it the
   **View** permission only, on the roles KN needs (for example
   `part_category`, `part`, `bom`, `stock_location`, `stock`; add
   `purchase_order`, `sales_order`, `build`, `pricing` only if needed). No
   Add, Change or Delete, and no `admin` role.
2. Create user `kn-exchange` with a strong password, member of `kn-read`
   only, with **Staff** and **Superuser** unset.
3. Issue the token once, over HTTPS with certificate verification. `curl -u`
   prompts for the password, so it stays out of the shell history:
   ```bash
   curl --cacert inventree-root-ca.crt -u kn-exchange \
     'https://inventree.lan:8443/api/user/me/token/?name=kn-exchange'
   ```
   The response `{"token": "..."}` is shown once. Store it in KN's secret
   store. Every new call with the same `name` revokes the previous token,
   so KN must not call this endpoint during normal operation. Tokens expire
   after 365 days by default; re-issue the token the same way before then.
   If MFA is set up or enforced for `kn-exchange`, basic auth is refused;
   generate the token in the web UI under user settings > Security instead.
4. Check the permissions without putting the token on the command line:
   ```bash
   printf 'Authorization: Token %s\n' "$(cat kn-token.txt)" > kn-header.txt   # chmod 600
   curl --cacert inventree-root-ca.crt -H @kn-header.txt https://inventree.lan:8443/api/user/me/roles/
   ```
   Expect only `view` entries.
5. KN sends `Authorization: Token <token>` and verifies the server against
   the root certificate ([network-tls.md](network-tls.md#client-trust)).

Write roles are added later, only after the owner approves writes. Add Add
or Change to specific roles of `kn-read` (or create a separate `kn-write`
group). Revoke tokens under Admin Center or user settings > Security.

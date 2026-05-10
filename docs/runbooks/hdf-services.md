# HDF Services

Hudsonville Digital Foundry business services run in the `hdf` namespace.

| Service | Domain | Auth |
| --- | --- | --- |
| Invoice Ninja | `https://portal.hudsonvilledigital.com` | Built-in Invoice Ninja auth |
| Chatwoot | `https://support.hudsonvilledigital.com` | Built-in Chatwoot auth |

Both public routes use the shared Traefik `public-chain` middleware. They are
not behind OAuth2-Proxy because clients and support users need the apps' native
login flows.

## Storage

RustFS runs in the `object-storage` namespace as the internal S3-compatible
object store for HDF app uploads. The Flux root is still named `storage`, but
the Kubernetes namespace `storage` is reserved for `local-path-provisioner`.

Buckets:

- `invoice-ninja`
- `chatwoot`

The first deployment provisions buckets with the `rustfs-create-buckets` Job.
Rotate the shared bootstrap object-store credentials into per-app credentials
once RustFS IAM management is wired into the cluster.

## Databases

Database placement:

- `invoice_ninja` lives on the MariaDB LXC at
  `registeel.internal.svc.cluster.local:3306`.
- `chatwoot` lives on the PostgreSQL LXC at
  `metagross.internal.svc.cluster.local:5432`.

Invoice Ninja uses in-process cache, signed-cookie sessions, and a sync queue
because the shared Redis disables destructive commands such as `FLUSHDB`, and
the upstream image expects writable app cache paths when file cache is enabled.
The upstream Debian image runs PHP-FPM; Kubernetes pairs it with an nginx
sidecar and shared `public`/`storage` PVCs, matching the upstream Docker Compose
layout.

The matching database passwords are sourced from local, gitignored Ansible vars
files and copied into each app's SOPS secret. For Invoice Ninja, keep
`ansible/inventory/group_vars/mariadb.yml` and
`kubernetes/hdf/invoice-ninja/secret.sops.yaml` in sync for `DB_PASSWORD`.

## Bootstrap

Invoice Ninja bootstraps an initial admin from:

- `IN_USER_EMAIL` in `kubernetes/hdf/invoice-ninja/configmap.yaml`
- `IN_PASSWORD` in `kubernetes/hdf/invoice-ninja/secret.sops.yaml`

Read the generated password locally with your SOPS age key:

```bash
SOPS_AGE_KEY_FILE=homelab.age.key sops -d kubernetes/hdf/invoice-ninja/secret.sops.yaml
```

Chatwoot account creation is handled through the first-run setup flow after the
app is reachable. Disable public account signup after the admin account exists
by setting `ENABLE_ACCOUNT_SIGNUP` to `false`.

## Manual Follow-Up

After both apps are reachable:

1. Create the Chatwoot admin account and website inbox.
2. Copy the Chatwoot widget snippet.
3. Add the widget to the Invoice Ninja client portal.
4. Configure real SMTP for both apps when client notifications are ready.

# webtrees

webtrees runs in the `apps` namespace at `https://family.mcnees.me`.

## Architecture

- App: `ghcr.io/nathanvaughn/webtrees:2.2.6`
- Database: `webtrees` on `registeel.internal.svc.cluster.local`
- Storage: `webtrees-data` local-path PVC mounted at `/var/www/webtrees/data`
- Themes/modules: `webtrees-modules` local-path PVC mounted at
  `/var/www/webtrees/modules_v4`
- Exposure: public Traefik entrypoint with the shared `public-chain` middleware
- Auth: webtrees built-in users and privacy controls

The legacy Gramps external route has been removed. There was no Gramps data to
migrate, so webtrees starts empty.

## Admin Login

The bootstrap admin is created only when the database is first initialized.

- Username: `admin`
- Email: `michael@mcnees.me`
- Password: `WT_PASS` from `kubernetes/apps/webtrees/secret.sops.yaml`

Read the generated password locally with:

```sh
SOPS_AGE_KEY_FILE=homelab.age.key sops -d kubernetes/apps/webtrees/secret.sops.yaml
```

## First-Run Checks

1. Open `https://family.mcnees.me`.
2. Sign in as `admin`.
3. Create the first tree from the web UI.
4. Confirm the site is not exposing living-person details publicly.
5. Create family member accounts manually until we decide on the invitation
   model.

## Themes

Custom themes live in `/var/www/webtrees/modules_v4` and persist on the
`webtrees-modules` PVC.

The Argon theme was installed from `~/Downloads/argon-2023.3.7.zip` into:

```text
/var/www/webtrees/modules_v4/argon
```

Enable it in the webtrees control panel after signing in as an administrator.

## Database

The `webtrees` database/user is managed by:

- `ansible/playbooks/mariadb-setup.yml`
- `ansible/inventory/group_vars/mariadb.yml`

If the app password is rotated, update both the local Ansible vars and the
SOPS-encrypted Kubernetes secret, then rerun:

```sh
task ansible:mariadb
```

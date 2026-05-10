# MariaDB

MariaDB runs as a dedicated Proxmox LXC named `mariadb`.

- OpenTofu module: `terraform/proxmox/mariadb.tf`
- IP address: `10.0.10.91`
- Kubernetes service: `mariadb.internal.svc.cluster.local:3306`
- Ansible playbook: `ansible/playbooks/mariadb-setup.yml`
- Local secret vars: `ansible/inventory/group_vars/mariadb.yml`

## Managed Databases

- `invoice_ninja`
- `grimmory`

Invoice Ninja is configured to use this host directly. Grimmory still needs a
dump/restore cutover from the existing in-cluster MariaDB pod before its app
manifest is pointed at the shared LXC.

## Bootstrap

Create the local Ansible vars file from the example:

```bash
cp ansible/inventory/group_vars/mariadb.yml.example ansible/inventory/group_vars/mariadb.yml
```

For existing apps, copy the password from the matching Kubernetes SOPS secret
instead of generating a new value. That lets the app move databases without a
credential rotation.

Apply the host and database configuration:

```bash
task infra:plan
task infra:apply
task ansible:mariadb
```

Then reconcile the database service and dependent apps:

```bash
flux reconcile kustomization databases -n flux-system
flux reconcile kustomization hdf -n flux-system
```

## Grimmory Cutover

After `task ansible:mariadb` succeeds and
`mariadb_password_grimmory` matches the current `grimmory-secret` DB password,
dump the in-cluster database into the LXC:

```bash
kubectl --kubeconfig talos/kubeconfig -n apps exec deploy/grimmory-mariadb -- \
  sh -c 'mariadb-dump -u grimmory -p"$MYSQL_PASSWORD" --single-transaction --routines --events --triggers grimmory' \
  > /tmp/grimmory.sql

kubectl --kubeconfig talos/kubeconfig -n apps run mariadb-client \
  --rm -i --restart=Never --image=mariadb:11.4 \
  --env MARIADB_PWD='<grimmory-db-password>' \
  -- mariadb \
    --host=mariadb.internal.svc.cluster.local \
    --port=3306 \
    --user=grimmory \
    grimmory < /tmp/grimmory.sql
```

Once the restore is verified, update Grimmory to use
`jdbc:mariadb://mariadb.internal.svc.cluster.local:3306/grimmory`, remove the
in-cluster MariaDB deployment from its kustomization, and delete the old PVC
only after a successful backup exists.

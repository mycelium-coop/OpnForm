# Production OpnForm on OVH VPS

This directory deploys one OpnForm instance to either a new classic OVH VPS or
an existing one. OpenTofu owns only OVH, Cloudflare DNS, and Cloudflare R2.
Ansible owns the server, host Caddy, Docker services, OIDC bootstrap, backups,
and immutable application releases.

## Prerequisites

- OpenTofu 1.12.5, Docker with Buildx, `just`, `op`, `restic`, `jq`, and `uv`.
  Python 3.12, Ansible 13.5.0, linting, Molecule, and their transitive Python
  dependencies are managed from `infra/ansible/pyproject.toml` and the
  committed `uv.lock`.
- A Cloudflare zone, an OVH account with a default payment method, and an R2
  account. The Cloudflare token needs DNS read/write, R2 bucket write, and
  optionally zone-settings write permissions.
- A 1Password item named `opnform-secrets` in the `tech-admin` vault with every
  field referenced by the repository-root `.env.example`.
- A private GHCR package namespace. The push token needs package write access;
  the VPS token needs only package read access.

Install controller dependencies once:

```sh
just python-sync
just doctor
```

`just python-sync` creates `infra/ansible/.venv` with the Python version pinned
in `.python-version`, synchronizes exactly from `uv.lock`, and installs the
pinned Ansible collections into `infra/ansible/.collections`. Both directories
are ignored. The Just recipes run Ansible through `uv run --locked`, so shell
activation is neither required nor used.

To change a Python dependency, edit `infra/ansible/pyproject.toml` and run:

```sh
just python-lock
just python-sync
uv lock --project infra/ansible --check
```

Commit `pyproject.toml` and `uv.lock` together. Review dependency changes before
syncing or deploying; `uv run --locked` refuses to operate with a stale lockfile.

## Configure and provision

Render the ignored local environment file from 1Password:

```sh
just env
chmod 600 .env
```

For a new VPS, set `VPS_MODE=create` and populate the OVH plan, image ID,
datacenter, and deployment SSH key fields. OpenTofu creates the VPS with
`prevent_destroy`; changing the image ID later cannot reinstall it.

For an existing VPS, set `VPS_MODE=existing` and `VPS_SERVICE_NAME` to its OVH
service name. OpenTofu reads the VPS but never imports, destroys, or reinstalls
it. Ansible requires a native systemd Caddy v2 service using a Caddyfile. It
preserves unrelated sites and adds only the managed import and
`opnform.caddy` snippet.

`ANSIBLE_SSH_USER` is the existing sudo-capable login Ansible uses. New Debian
VPS images normally use `debian`; set `ubuntu` for Ubuntu or the appropriate
administrator account for an existing VPS. The automation creates the separate
`DEPLOY_USER` account for the service and future operations.

Create the remote state and backup buckets, then migrate the production state
to R2:

```sh
just bootstrap-init
just bootstrap-plan
CONFIRM_PROD=opnform-production just bootstrap-apply
CONFIRM_PROD=opnform-production just bootstrap-migrate
just init
just plan
just show-plan
CONFIRM_PROD=opnform-production just apply
```

Replace `opnform-production` with the `DEPLOYMENT_NAME` in `.env`. Do not apply
without reviewing the saved plan. Every production plan first writes an
encrypted R2 state snapshot. On the first plan, the state snapshot is skipped
because no production state exists yet; the encrypted restic repository is
initialized automatically before the first snapshot that has state to save.

Verify the VPS SSH host key out-of-band, then generate its ignored inventory:

```sh
just inventory
ssh -i "$SSH_PRIVATE_KEY_PATH" "$DEPLOY_USER@<vps-ip>"
```

The initial release creates the first administrator and, when `OIDC_ENABLED`
is true, creates the workspace OIDC connection. Register this callback URI in
the identity provider:

```text
https://<OPNFORM_HOSTNAME>/auth/<OIDC_SLUG>/callback
```

The site remains in maintenance mode during bootstrap and is opened only after
the administrator and requested OIDC connection are configured.
The bootstrap creates a least-privilege OIDC automation token on the VPS; later
`just deploy` runs reconcile changes to the configured OIDC issuer, mappings,
and client secret without storing that automation token in OpenTofu or 1Password.

## Release and operations

Create an immutable release from a clean committed worktree:

```sh
CONFIRM_PROD=opnform-production just release
```

The command lints/tests the checkout, builds Linux AMD64 API and client images,
scans them, pushes them to GHCR, resolves immutable digests, creates a backup,
and deploys through Ansible. Application releases use a short maintenance
window because the API container applies migrations at startup.

Use these day-two commands:

```sh
just status
just logs
CONFIRM_PROD=opnform-production just backup
just backup-check
CONFIRM_PROD=opnform-production just rollback sha-<40-character-commit>
CONFIRM_PROD=opnform-production just restore <restic-snapshot-id>
```

A rollback restores the previous image bundle. If a migration is incompatible,
the release workflow restores the pre-release database/uploads snapshot; do not
manually alter OpenTofu state or force-unlock it without confirming that no
operation is active.

## Security notes

- `.env`, generated inventories, local plans, state snapshots, and release
  manifests are ignored and use mode `0600` or stricter.
- No application secret is an OpenTofu input, output, or state value.
- Docker registry passwords are supplied through stdin; Ansible suppresses logs
  and diffs for every secret-bearing task.
- Caddy exposes only the loopback Docker ingress. With Cloudflare proxying
  enabled, the OpnForm site rejects direct-origin peers while other Caddy sites
  retain their own policy.
- Existing VPS mode does not alter the global firewall by default. New VPS mode
  enables UFW for administrative SSH CIDRs and ports 80/443.

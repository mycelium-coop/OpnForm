# Fork infrastructure agent instructions

These rules apply when working on this fork's deployment stack:
`infra/`, `scripts/infra/`, `scripts/migrate_form.py`, the root `Justfile`,
or root `.env.example`. Also see [FORK.md](./FORK.md) for the upstream
baseline and allowlisted upstream edits.

## Commit Messages

- Never add a `Co-Authored-By: Claude ...` (or similar AI attribution) trailer to commit messages.

## Infrastructure Automation

The production infrastructure lives under `infra/` and is orchestrated by the
root `justfile` through `scripts/infra/`. Prefer the documented `just` recipes
over ad-hoc `tofu`, Ansible, or state commands because the wrappers load the
correct variables, configure the backend, take state snapshots, and enforce
production confirmation.

### Upstream Releases and Fork Maintenance

- Production updates must target an explicitly selected stable upstream release
  tag. Treat instructions elsewhere to update from upstream `main` as
  development-only. Merge the selected release into the fork, preserve its
  customizations, and deploy tested fork images pinned by digest.
- Keep `infra/upstream-baseline` truthful. Do not relabel a baseline containing
  unreleased commits, reset history, or downgrade without a separately scoped
  request. A version label derived from the newest tag contained in a commit
  does not prove that the deployed code matches that release.
- Before attributing a regression to upstream, compare the affected commit with
  the stable release and check upstream issues and fixes. Distinguish reproduced
  failures from inferred risks.
- Keep upstream-owned edits small. Document intentional exceptions in both
  `infra/FORK.md` and `scripts/infra/check-upstream-allowlist.sh`.

### Routing Ownership and Nuxt Icons

Production uses one hostname: the frontend at `https://forms.mycelium.coop`
and the browser API at `/api`, with Caddy forwarding to unchanged upstream
Nginx (`docker/nginx.conf`).

- Deploy `docker/nginx.conf` verbatim into each release bundle and mount that
  file at the Nginx template path. Checksum the mounted template, not the
  env-substituted config. Independently maintained Nginx templates are not
  allowed.
- Put fork-specific routing in Caddy: rewrite exact `/v` to `/api/v`, and
  legacy `/api/_nuxt_icon/*` to `/_nuxt_icon/*`. Keep those rewrites inside a
  `route` that places maintenance ahead of the Cloudflare gate so maintenance
  answers every client, including Cloudflare.
- Nuxt Icon uses `icon.localApiEndpoint: '/_nuxt_icon'`. That changes both
  server endpoint registration and client requests at build time; rebuild the
  client image after changing it. Redeploying an old client leaves browsers on
  `/api/_nuxt_icon/*`, which is why the legacy rewrite remains as new-server
  compatibility only.
- Upstream Nginx expects `opnform-client`, `opnform-api`, and
  `NGINX_MAX_BODY_SIZE`. When adding Docker network aliases, ensure workers and
  scheduler do not inherit the API alias through a shared Compose anchor.
- Both active Caddy proxies force `X-Forwarded-Port` to `443` for the
  production HTTPS origin. The Cloudflare gate alone replaces visitor IP from
  `CF-Connecting-IP`; the non-lockdown proxy keeps Caddy’s default client IP
  handling.

### Deployment Activation and Verification

- Capture recovery artifacts and establish verified maintenance before the
  `caddy` or `opnform` roles change live configuration. Writing a maintenance
  file is not enough; probe for a 503 response.
- Upstream Nginx resolves backend names at startup. Recreate ingress after
  backend replacements, before requiring the complete stack to pass health
  checks.
- Store Nginx and Caddy artifacts with each retained release. Recovery
  snapshots must not be overwritten by retries. Rollback selects the target
  release’s client, Caddy files, and Nginx mount. While restoring a pre-change
  site whose maintenance ordering is unsafe, keep a maintenance overlay that
  does not depend on that site’s `handle` order.
- Verify `/v` content and the expected deployed image SHA through public Caddy.
  Private checks use `/api/v` and `/_nuxt_icon/*`. Assert SVG bodies for
  heroicons and material-symbols; HTTP 200 alone is insufficient.
- Run `just routing-check` for the isolated harness.

### Environment Files

- Root `.env` is generated, ignored, and secret-bearing. Never print it, commit
  it, or replace user values while making template changes.
- `just env` renders `.env` and sets mode `0600`. If `.env` is created or
  populated outside that recipe, run `chmod 600 .env` manually.
- `.env.example` is consumed by multiple dotenv/shell tools. Keep every entry
  on one `KEY=value` line and quote defaults containing whitespace, wildcard
  characters, schedules, or JSON. A relevant example is
  `BACKUP_SCHEDULE="*-*-* 02:15:00"`.
- An empty exported value overrides an OpenTofu variable default. Validate
  required non-secret settings before planning; in particular, an empty
  `OIDC_SLUG` produces an invalid `/auth//callback` URI.
- `IMAGE_PLATFORM` must match the VPS architecture. On Ubuntu, use
  `dpkg --print-architecture`; map `amd64` to `linux/amd64` and `arm64` to
  `linux/arm64`.

### OVH and Cloudflare R2

- `OVH_ENDPOINT`, the API credentials, subsidiary, and VPS region must agree.
  US accounts use `OVH_ENDPOINT=ovh-us`; a service name ending in
  `.vps.ovh.us` is a strong indication that it belongs to the US API.
- The bootstrap stack creates R2 buckets in the EU jurisdiction. Their S3 API
  endpoint is `https://<R2_ACCOUNT_ID>.eu.r2.cloudflarestorage.com`; omitting
  `.eu` can produce misleading `403 Forbidden`/`HeadObject` migration errors.
- State and backup credentials are separate and need Object Read & Write access
  to their respective buckets. Treat a migration `403` as an endpoint,
  credential, token-scope, or bucket-permission problem; do not retry with
  destructive state commands.

### OpenTofu Workflow and State Safety

- The repository pins OpenTofu `1.12.5`, Cloudflare provider `~> 5.22.0`, and
  OVH provider `~> 2.18.0`. Keep runtime/provider upgrades separate from
  functional infrastructure changes and preserve the lock files.
- First-time bootstrap is intentionally local, followed by a reviewed bootstrap
  apply and `CONFIRM_PROD=<DEPLOYMENT_NAME> just bootstrap-migrate`. In a fresh
  checkout after migration, use `just bootstrap-remote-init`; do not restart the
  local bootstrap flow.
- Backend declarations, backend mode markers, backend configuration, local
  bootstrap state, saved plans, and `.terraform/` metadata are managed by the
  scripts. Do not hand-edit state or generated backend files, commit them, or
  delete migration backups before remote state has been verified.
- Use `just plan`, inspect the exact saved artifact with `just show-plan`, and
  apply only that artifact through `CONFIRM_PROD=<DEPLOYMENT_NAME> just apply`.
  Never substitute a fresh direct apply. `just plan` contacts providers and
  writes an encrypted pre-plan state snapshot to the backup bucket, so it is
  not a purely offline validation command.
- Never force-unlock or push state unless the active operation has been ruled
  out and a verified recovery snapshot exists. Do not use `-target` or
  `-exclude` to hide a dependency-graph defect in the normal deployment flow.
- Resource `count` and `for_each` shapes must be known during planning. Do not
  derive them from computed VPS attributes such as `data.ovh_vps.selected.ips`;
  use a plan-time input such as `CLOUDFLARE_MANAGE_IPV6_RECORD`, then validate
  the computed address with a precondition. Prefer implicit dependencies from
  references; an unnecessary `depends_on` on a data source can defer it until
  apply and make otherwise-known values unknown.
- If `CLOUDFLARE_MANAGE_IPV6_RECORD=true`, the VPS must report an IPv6 address.
  Set it to `false` for IPv4-only hosts rather than weakening the precondition.
- `just validate` avoids reinitializing a cached S3 backend. On a fresh checkout
  it may initialize provider plugins and therefore require network access.

### Infrastructure Validation

- Shell changes: `bash -n scripts/infra/*.sh` (or the specific changed files).
- OpenTofu changes: `just fmt-check`, then `just validate`.
- Ansible changes: use the verification commands in the Ansible section below.
- For behavior affecting a production plan, run `just plan` only when provider
  access and the backup side effect are in scope, then report the add/change/
  destroy summary and any warnings. Never apply merely to prove a fix.

# Ansible Automation

## Project Stack
- ansible-core 2.20.4, Ansible community package 13.5.0
- Python 3.12+ required for controller and managed nodes
- Python dependencies and the controller `.venv` are managed by `uv` from
  `infra/ansible/pyproject.toml` and `infra/ansible/uv.lock`.
- Execution Environments built with ansible-builder 3.x
- Molecule 25.x for role testing with Podman driver

## Anti-Hallucination Rules
- NEVER invent module parameters. Check `ansible-doc <module>` first.
- NEVER use deprecated `include:` — use `ansible.builtin.include_tasks`
  or `ansible.builtin.import_tasks` with FQCNs.
- ALL module references MUST use fully qualified collection names (FQCNs):
  `ansible.builtin.copy`, NOT `copy`.
- Handler names are global within a play. NEVER duplicate handler names
  across roles unless intentionally overriding.
- `become: true` is required for privilege escalation. Do NOT assume
  root access on managed hosts.
- Ansible 13 dropped Python 3.10 support on the controller. Do NOT
  generate code targeting Python < 3.11.

## Verification Commands
- Environment sync: `just python-sync`
- Lint: `(cd infra/ansible && uv run --locked -- ansible-lint --strict site.yml restore.yml roles/)`
- Syntax check: `(cd infra/ansible && uv run --locked -- ansible-playbook --syntax-check site.yml)`
- Dry run: `(cd infra/ansible && uv run --locked -- ansible-playbook --check --diff site.yml)`
- Molecule test: `(cd infra/ansible && uv run --locked -- molecule test)`
- Collection build: `(cd infra/ansible && uv run --locked -- ansible-galaxy collection build --force)`

## Directory Conventions
- `roles/` — one directory per role, each with `tasks/`, `handlers/`,
  `defaults/`, `meta/`, `molecule/`
- `inventories/` — per-environment inventory (dev, staging, prod)
- `group_vars/` and `host_vars/` — variable hierarchy
- `collections/requirements.yml` — pinned collection dependencies
- `execution-environments/` — EE definitions for ansible-builder

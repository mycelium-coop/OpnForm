# AGENTS.md

Instructions for AI coding agents working in this repository.

## Scope

- This file applies to the full repository.
- If a deeper `AGENTS.md` exists in a subdirectory, follow the deeper file for files in that subtree.

## Repository Overview

- Monorepo with:
- `api/`: Laravel 11+ / PHP 8.3 backend.
- `client/`: Nuxt 3 / Vue frontend (JavaScript, not TypeScript by default).
- `docs/`: Mintlify documentation.

## Working Style

- Make focused changes that directly solve the request.
- Prefer editing existing patterns over introducing new architecture.
- Keep diffs small and avoid unrelated refactors.
- Preserve existing conventions and file organization.

## Setup And Commands

- Frontend (`client/`):
- Install: `npm install`
- Dev server: `npm run dev`
- Lint: `npm run lint`
- Tests: `npm run test`
- Backend (`api/`):
- Install: `composer install`
- Tests: `php artisan test`

## Validation Before Handoff

- Run targeted checks for changed areas first.
- If frontend code changed, run `npm run lint` (in `client/`) and relevant tests.
- If backend code changed, run relevant `php artisan test --filter=...` and broaden only if needed.
- Report what was run and what could not be run.

## Codex Worktrees

- Codex worktrees use the managed environment in `.codex/environments`.
- The setup action provisions an isolated PostgreSQL Docker volume and seeded local Laravel/Nuxt stack for the current checkout.
- Use the `Start app`, `Reset DB`, `Stop app`, and `Run E2E` actions, or their `scripts/codex-worktree-*.sh` equivalents.
- The scripts print the worktree-specific UI URL. Verify this URL before trusting browser results; do not use the shared `docker-compose.dev.yml` stack for worktree checks.
- Opening the worktree root URL signs in the seeded global and workspace admin automatically. Its credentials are `e2e@example.test` / `Abcd@1234` for manual and automated tests.
- The seed includes three sample forms and five completed submissions across two public forms.

## Project Conventions

- Frontend:
- Use Nuxt UI v3 + Tailwind patterns already used in the codebase.
- Prefer Composition API and existing composables.
- Use Promise chaining style (`.then().catch().finally()`) where this project already enforces it.
- Backend:
- Follow Laravel conventions, Form Requests, Eloquent relationships, and Pest tests.
- Keep controllers thin and place business logic in services when appropriate.

## Cursor Rules (Source Of Truth)

- For detailed conventions, read and follow:
- [`.cursor/rules/opnform-overview.mdc`](./.cursor/rules/opnform-overview.mdc)
- [`.cursor/rules/front-end.mdc`](./.cursor/rules/front-end.mdc)
- [`.cursor/rules/api-query.mdc`](./.cursor/rules/api-query.mdc)
- [`.cursor/rules/front-end-testing.mdc`](./.cursor/rules/front-end-testing.mdc)
- [`.cursor/rules/back-end.mdc`](./.cursor/rules/back-end.mdc)
- [`.cursor/rules/back-end-testing.mdc`](./.cursor/rules/back-end-testing.mdc)
- [`.cursor/rules/forms.mdc`](./.cursor/rules/forms.mdc)
- [`.cursor/rules/formula-engine.mdc`](./.cursor/rules/formula-engine.mdc)
- [`.cursor/rules/docs.mdc`](./.cursor/rules/docs.mdc)

## Documentation Changes

- When behavior, configuration, or workflows change, update docs in `README.md`, `docs/`, or both.

## Safety

- Do not commit secrets or tokens.
- Do not change licensing files or enterprise-only code boundaries unless explicitly requested.

## Commit Messages

- Never add a `Co-Authored-By: Claude ...` (or similar AI attribution) trailer to commit messages.

## Infrastructure Automation

The production infrastructure lives under `infra/` and is orchestrated by the
root `justfile` through `scripts/infra/`. Prefer the documented `just` recipes
over ad-hoc `tofu`, Ansible, or state commands because the wrappers load the
correct variables, configure the backend, take state snapshots, and enforce
production confirmation.

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

## Cursor Cloud specific instructions

### Project overview

OpnForm is a no-code form builder with two main services: a **Laravel 11 API** (`api/`) and a **Nuxt 3 client** (`client/`). Development uses Docker Compose (`docker-compose.dev.yml`) which runs PostgreSQL, the API (PHP-FPM), the client (Nuxt dev server), and an Nginx ingress.

### Starting the dev environment

```bash
# Docker must be running first (see Docker gotcha below)
cd /workspace && docker compose -f docker-compose.dev.yml up -d
```

Wait ~60s for the client container to finish `npm install` + Nuxt build on first start. The app is then available at `http://localhost:3000` (client) and `http://localhost` (API via Nginx).

On first run, navigate to `http://localhost:3000/setup` to create the admin account.

### Docker gotcha (nested containers)

This cloud environment runs inside a container, so Docker requires `fuse-overlayfs` storage driver and `iptables-legacy`. The daemon config at `/etc/docker/daemon.json` is already set. To start dockerd:

```bash
sudo dockerd &>/tmp/dockerd.log &
sleep 3
sudo chmod 666 /var/run/docker.sock
```

### Stale Docker API image

The published `jhumanj/opnform-api:dev` image may lag behind the repo's `composer.json`. If the API container fails with missing class errors (e.g. `TwoFactorServiceProvider not found`), run:

```bash
docker exec opnform-api sh -c "curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer"
docker exec opnform-api composer install --no-interaction --optimize-autoloader
docker restart opnform-api
```

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

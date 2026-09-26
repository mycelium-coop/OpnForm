# Mycelium fork maintenance

This document tracks how this repository diverges from upstream
[OpnForm/OpnForm](https://github.com/OpnForm/OpnForm) while keeping the OVH
deployment stack under `infra/` merge-friendly.

## Upstream baseline

- **Original fork point:** `3a1b5abd3f6327aa90ff7ba123423df756e8f66e`
  (“Add audio block support and related components”, 2026-08-03)
- **Latest incorporated upstream tip:** the full SHA in
  [`infra/upstream-baseline`](./upstream-baseline). The allowlist guard
  (`scripts/infra/check-upstream-allowlist.sh`) compares against this file,
  not the original fork point, so merging newer upstream commits does not
  fail CI as unexpected fork drift.
- Fetch with: `git fetch https://github.com/OpnForm/OpnForm.git main`
- Compare with:
  `git diff "$(cat infra/upstream-baseline)"..upstream/main`

## Fork-owned paths

These paths are owned by this fork and are not expected to match upstream:

- `infra/` (including `infra/docker/`, `infra/AGENTS.md`, this file)
- `scripts/infra/`
- `scripts/migrate_form.py`
- `scripts/cloudflare-ip-ranges.py`
- `scripts/form-migration.env.example`
- `scripts/tests/test_migrate_form.py`
- `scripts/.gitignore`
- root `Justfile`
- root `.env.example`
- root `CLAUDE.md` (symlink to `AGENTS.md`)

## Allowlisted upstream edits

Only these upstream-owned files may differ from the baseline (aside from
merging newer upstream commits into them):

| Path | Why it remains |
| --- | --- |
| `AGENTS.md` | Short pointer to `infra/AGENTS.md` and this file so Codex/Cursor load fork rules for infra work |
| `api/config/app.php` | Registers `SelfHostedOidcSanctumServiceProvider` so bootstrap tokens can manage OIDC connections without editing `sanctum-routes.php` |
| `api/app/Providers/SelfHostedOidcSanctumServiceProvider.php` | Fork-only provider that appends OIDC Sanctum route names at boot |
| `api/tests/Feature/SelfHosted/SelfHostedOidcSanctumRoutesTest.php` | Covers the OIDC Sanctum allowlist append |
| `client/components/workspaces/settings/sso/Oidc.vue` | Hoists `updateMutation` into setup; `useMutation()` cannot run inside a click handler |

Any other change under upstream-owned trees should be reverted or moved into
fork-owned paths.

## Production Dockerfiles

Fork production builds use:

- `infra/docker/Dockerfile.api`
- `infra/docker/Dockerfile.client`

with complete ignore files:

- `infra/docker/Dockerfile.api.dockerignore`
- `infra/docker/Dockerfile.client.dockerignore`

**Baseline for the copies:** upstream `docker/Dockerfile.*` at `3a1b5abd`, plus
OCI image labels and the API `COMPOSER_FLAGS` default (`--no-dev`).

Upstream CI still builds `docker/Dockerfile.api` and `docker/Dockerfile.client`.
When merging upstream, diff those files against the baseline and replay any
upstream fixes into `infra/docker/` by hand. The copies do not inherit changes
automatically.

## Retained patches and tests

| Patch | Test / check |
| --- | --- |
| `SelfHostedOidcSanctumServiceProvider` | `php vendor/bin/pest --filter='DualAuthMiddlewareTest|SelfHostedOidcSanctumRoutesTest'` from `api/` (after the env prep in `scripts/infra/release.sh` `release_check`) |
| `Oidc.vue` `updateMutation` hoist | Manual SSO settings UI; no dedicated automated test |
| `infra/docker` images | `scripts/infra/check-fork-images.sh` |

## Updating from upstream

1. Fetch and merge upstream `main` into this branch.
2. Set `infra/upstream-baseline` to the incorporated upstream tip (the merge
   parent from upstream, or `upstream/main` after a fast-forward). Commit that
   file with the merge so the allowlist guard measures only fork differences.
3. Diff `docker/Dockerfile.api` and `docker/Dockerfile.client` against the
   previous baseline; update `infra/docker/` if needed.
4. Run the allowlist guard:
   `bash scripts/infra/check-upstream-allowlist.sh`
   (also runs in `.github/workflows/fork-upstream-guard.yml`).
5. Run `bash scripts/infra/check-fork-images.sh` when Dockerfiles or their
   ignore files changed.
6. From `api/`, with the same env prep as `release_check`, run:

   ```bash
   php -d memory_limit=512M ./vendor/bin/pest --filter='DualAuthMiddlewareTest|SelfHostedOidcSanctumRoutesTest'
   php -d memory_limit=512M ./vendor/bin/pest --filter='RegisterTest|WorkspaceInviteLimitTest|ProvisioningServiceTest'
   ```

## Release manifest location

New manifests are always written to `infra/.deploy/releases/` via
`new_release_manifest`. Readers still fall back to the legacy repo-root
`.deploy/releases/` path through `release_manifest`.

One-time file-level migration (safe when the destination already has
manifests from a newer publish). Preserves modes, skips IDs that already
exist under `infra/.deploy/releases/`, and does not overwrite them:

```sh
mkdir -p infra/.deploy/releases
if [ -d .deploy/releases ]; then
  for src in .deploy/releases/*.env; do
    [ -e "$src" ] || continue
    dest="infra/.deploy/releases/$(basename "$src")"
    if [ -e "$dest" ]; then
      printf 'skip existing %s\n' "$dest"
      continue
    fi
    cp -p "$src" "$dest"
    printf 'migrated %s\n' "$dest"
  done
fi
```

After verifying deploys resolve the new path, remove the legacy directory:

```sh
rm -rf .deploy/releases
```
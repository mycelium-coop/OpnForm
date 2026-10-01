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
- **Current baseline:** `e087b570182571ee721e1564d8d03347ed327c10`. That
  commit contains 12 upstream commits after the newest stable tag
  (`v2.5.0`). Keep the SHA truthful; do not relabel it as `v2.5.0`.
  Reconciling onto a later stable tag is a separate maintenance task.
- **Production update policy:** merge an explicitly selected **stable
  upstream release tag**, preserve fork customizations, and deploy digest-
  pinned fork images. Treat instructions that say to merge upstream `main`
  as development-only.
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
| `api/config/app.php` | Registers fork providers for OIDC Sanctum routes and the public `/v` version endpoint |
| `api/app/Providers/SelfHostedOidcSanctumServiceProvider.php` | Fork-only provider that appends OIDC Sanctum route names at boot |
| `api/app/Providers/SelfHostedVersionEndpointServiceProvider.php` | Fork-only provider that registers public plain-text `GET /v` |
| `api/tests/Feature/SelfHosted/SelfHostedOidcSanctumRoutesTest.php` | Covers the OIDC Sanctum allowlist append |
| `api/tests/Feature/SelfHosted/SelfHostedVersionEndpointTest.php` | Covers the plain-text `/v` version body |
| `client/components/workspaces/settings/sso/Oidc.vue` | Hoists `updateMutation` into setup; `useMutation()` cannot run inside a click handler |
| `client/nuxt.config.ts` | Sets `icon.localApiEndpoint: '/_nuxt_icon'` so Nuxt Icon stays outside Laravel `/api`. Enforced by `scripts/infra/check-nuxt-icon-endpoint.sh`. |

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
OCI image labels, the API `COMPOSER_FLAGS` default (`--no-dev`), and
`APP_VCS_REF` so `/v` can report the fork commit.

Upstream CI still builds `docker/Dockerfile.api` and `docker/Dockerfile.client`.
When merging upstream, diff those files against the baseline and replay any
upstream fixes into `infra/docker/` by hand. The copies do not inherit changes
automatically.

## Retained patches and tests

| Patch | Test / check |
| --- | --- |
| `SelfHostedOidcSanctumServiceProvider` | `php vendor/bin/pest --filter='DualAuthMiddlewareTest|SelfHostedOidcSanctumRoutesTest'` from `api/` (after the env prep in `scripts/infra/release.sh` `release_check`) |
| `SelfHostedVersionEndpointServiceProvider` | `php vendor/bin/pest --filter='SelfHostedVersionEndpointTest'` from `api/` |
| `Oidc.vue` `updateMutation` hoist | Manual SSO settings UI; no dedicated automated test |
| `client/nuxt.config.ts` icon endpoint | `bash scripts/infra/check-nuxt-icon-endpoint.sh` |
| `infra/docker` images | `scripts/infra/check-fork-images.sh` |
| Upstream Nginx + Caddy routing | `just routing-check` |

## Updating from upstream

1. Select a stable upstream release tag (or, for development only, fetch
   upstream `main`). Merge it into this branch while preserving fork
   customizations.
2. Set `infra/upstream-baseline` to the incorporated upstream tip (the merge
   parent from upstream, or the selected tag’s commit). Commit that
   file with the merge so the allowlist guard measures only fork differences.
   The next image build sets `APP_VERSION` to the newest `vX.Y.Z` tag on
   OpnForm/OpnForm that is contained in this baseline.
3. Diff `docker/Dockerfile.api` and `docker/Dockerfile.client` against the
   previous baseline; update `infra/docker/` if needed.
4. Run the allowlist and Nuxt icon guards:
   `bash scripts/infra/check-upstream-allowlist.sh`
   `bash scripts/infra/check-nuxt-icon-endpoint.sh`
   (also run in `.github/workflows/fork-upstream-guard.yml`).
5. Run `bash scripts/infra/check-fork-images.sh` when Dockerfiles or their
   ignore files changed.
6. Run `bash scripts/infra/routing-check.sh` (or `just routing-check`) when
   Nginx, Caddy, Compose, or icon routing changed.
7. From `api/`, with the same env prep as `release_check`, run:

   ```bash
   php -d memory_limit=512M ./vendor/bin/pest --filter='DualAuthMiddlewareTest|SelfHostedOidcSanctumRoutesTest|SelfHostedVersionEndpointTest'
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
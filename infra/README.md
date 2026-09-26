# Production OpnForm on OVH VPS

This directory deploys one OpnForm instance to either a new classic OVH VPS or
an existing one. OpenTofu owns only OVH, Cloudflare DNS, and Cloudflare R2.
Ansible owns the server, host Caddy, Docker services, OIDC bootstrap, backups,
and immutable application releases.

## End-to-end flow

1. Install controller tools and sync Python/Ansible dependencies.
2. Create the `tech-admin` / `opnform-secrets` 1Password item.
3. Render `.env` with `just env`, then set local mode knobs (`VPS_MODE`, OIDC).
4. Bootstrap R2 buckets, migrate bootstrap state, apply production OpenTofu.
5. Trust the VPS SSH host key, generate inventory, confirm SSH works.
6. Run `just release` from a clean commit (build → scan → push → deploy → smoke).
7. Confirm `https://<OPNFORM_HOSTNAME>` and OIDC callback registration.

Destructive or state-changing commands require
`CONFIRM_PROD=<DEPLOYMENT_NAME>` (must match `.env` exactly).

## Prerequisites

Controller tools:

- OpenTofu **1.12.5**, Docker with Buildx, `just`, `op`, `restic`, `jq`, `uv`,
  `git`, `curl`, `npm`, **PHP 8.3 or 8.4**, `composer`, and **Trivy**. Prefer
  PHP 8.3; Homebrew’s default `php` formula may already be 8.5+, which
  `api/composer.lock` does not yet allow.
- Local package installs in the app trees, because `just release` /
  `just release-check` run `npm run lint` in `client/` and `./vendor/bin/pest`
  in `api/` (not `php artisan test`; Collision/Pest are in Laravel
  `dont-discover` so the Artisan command is not registered):
  - `(cd client && npm install)` — provides `eslint` via `node_modules/.bin`
  - `(cd api && composer install)` — provides `vendor/autoload.php` and Pest
  - Release checks copy `api/.env.example` to `api/.env` when missing (same as
    CI) and clear stale `bootstrap/cache` route/event caches before Pest runs
  - `SKIP_TESTS=1` skips Pest while still running lint and the dirty-tree
    check (`just release`, `just release-check`, `just build`, `just publish`)
- Python 3.12, Ansible 13.5.0, linting, Molecule, and their transitive Python
  dependencies are managed from `infra/ansible/pyproject.toml` and the
  committed `uv.lock`.

On macOS with Homebrew, a typical tool install looks like:

```sh
brew install just opentofu jq restic uv node php@8.3 composer trivy
brew unlink php 2>/dev/null || true
brew link php@8.3 --force --overwrite
php -v   # must report 8.3.x (or 8.4.x)
(cd client && npm install)
(cd api && composer install)
```

Also install the 1Password CLI (`op`) and Docker Desktop (with Buildx). Pin or
verify OpenTofu **1.12.5** after install (`tofu version`). Confirm
`docker info` works before releasing. Docker Desktop on macOS often uses
`~/.docker/run/docker.sock` via the `desktop-linux` context rather than
`/var/run/docker.sock`; `just release` preserves that endpoint when it uses an
isolated Docker config for GHCR login. Release builds also create a
`docker-container` Buildx builder (`opnform-release`) because provenance/SBOM
attestations are not supported by Desktop’s default `docker` driver.

Release caching:

- Buildx configuration stays in `BUILDX_CONFIG` (or the original Docker config's
  `buildx` directory), separate from the temporary GHCR login credentials. The
  persistent `opnform-release` builder retains local layers and dependency caches.
- `just publish` and `just release` import/export registry caches in each image
  repository under `buildcache-linux-amd64` (or the corresponding
  `IMAGE_PLATFORM` with slashes replaced by hyphens). `mode=max` retains
  intermediate build stages. These mutable cache tags are separate from immutable
  release tags and digest-pinned manifests; keep their package access restricted
  like the images because the cache includes intermediate application source.
- A missing registry cache is normal on the first build. Cache export failures
  produce warnings rather than failing an otherwise successful image publish.
- Composer dependencies are cached by their manifests; application autoloading
  and Laravel scripts still run after source is copied. Composer/npm download
  cache mounts persist locally on the builder, not in the registry cache.
- Version metadata is applied after filesystem layers, so changing the commit
  or build timestamp does not recompile PHP extensions. The first build after
  these Dockerfile changes warms the new cache; later builds benefit from reuse.

Use `BUILDKIT_PROGRESS=plain just publish` to inspect step timings and `CACHED`
markers during an intended publish. Dependency or base-image updates still
invalidate the relevant layers; pruning the builder removes its local caches.

Accounts and resources:

- A Cloudflare zone for the OpnForm hostname, an OVH account with a default
  payment method, and Cloudflare R2 enabled on the same account.
- A private GHCR package namespace for the API and client images.
- A 1Password item named `opnform-secrets` in the `tech-admin` vault. Create
  the fields you need for the current stage (see
  [Secrets checklist](#secrets-checklist)); `just env` warns about missing
  fields and leaves those variables empty instead of failing. Exception:
  `ovh-ssh-password`, which `just env` / deploy create when missing. Field
  names must match the last segment of each
  `op://tech-admin/opnform-secrets/<field>` reference in the repository-root
  `.env.example`.

Install controller dependencies once:

```sh
just python-sync
just doctor
```

`just doctor` verifies the controller CLIs (including npm, PHP 8.3/8.4,
Composer, and Trivy), that `client/node_modules` and `api/vendor` are present,
the uv lock/environment, Ansible collections, OpenTofu 1.12.5, and Docker
Buildx. It does not contact OVH, Cloudflare, or the VPS. Builds target
`IMAGE_PLATFORM` (default `linux/amd64`); on Apple Silicon, ensure Docker
Buildx can build and push amd64 images.

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

## Secrets checklist

`just env` runs `op inject` against `.env.example` and writes an ignored root
`.env` with mode `0600`. Sign in to 1Password first (`op signin`), then create
or update the `tech-admin` / `opnform-secrets` item with the fields needed for
your current stage. Prefer one Login or Secure Note item with custom fields
named exactly as below. Missing fields are left empty and listed as warnings so
early steps such as R2 bootstrap can proceed without every deploy-time secret.

After the item has at least the secrets for the next step:

```sh
just env
```

`just env` refuses to overwrite an existing `.env`. To re-render:

```sh
CONFIRM_ENV_CLEAN="$PWD/.env" just env-clean
just env
```

`just env` sets the generated `.env` mode to `0600` automatically. Run
`chmod 600 .env` only if you create or replace `.env` outside `just env`.

`CONFIRM_ENV_CLEAN` must be the absolute path to the repo `.env`, not the
deployment name. Non-secret defaults in the generated file may be edited
locally; keep shell-safe quoting. See
[Local `.env` knobs](#local-env-knobs) after rendering.

OpenTofu Cloudflare and OVH providers authenticate from process environment
variables loaded out of `.env` (`CLOUDFLARE_API_TOKEN`, `OVH_*`). Application
secrets are never OpenTofu inputs, outputs, or state values. The R2 S3 backend
maps `R2_STATE_*` into `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` only for
state operations.

### OVH credentials and VPS selection

| 1Password field | Purpose | How to create or find it |
| --- | --- | --- |
| `ovh-application-key` | OVH Application Key (AK) | Create an API application at [api.ovh.com/createToken](https://api.ovh.com/createToken/) (or the matching regional portal for `OVH_ENDPOINT`). Store the Application Key. |
| `ovh-application-secret` | OVH Application Secret (AS) | Shown once when the application is created. |
| `ovh-consumer-key` | OVH Consumer Key (CK) | Issued with the token after you approve the requested rights. |
| `ovh-subsidiary` | Billing subsidiary for new orders | Two-letter subsidiary code used by OVH cart orders, for example `FR`, `DE`, `IE`, `PL`, or `US`. Use the subsidiary of the OVH account that will be billed. |
| `ovh-vps-plan-code` | VPS commercial plan | Required only for `VPS_MODE=create`. Discover codes with the OVH API console under `/order` / VPS catalog (for example `vps-2025-model*` / `vps-2027-model*`), or copy the plan code from an order confirmation for the SKU you want. |
| `ovh-vps-datacenter` | Datacenter label | Required only for create mode. Examples: `GRA`, `SBG`, `BHS`, `WAW`. Choose a datacenter where the selected plan is available. |
| `ovh-vps-image-id` | OS image UUID | Required only for create mode so OpenTofu can inject the deploy SSH public key at provision time. List images from the OVH VPS API / Control Panel for the chosen plan and OS (`Ubuntu 26.04` by default in `.env.example`). Changing this later cannot reinstall an existing VPS. |

Modern OVH VPS catalogs (including `vps-2027-model*`) also require **mandatory cart
options** such as `storage`, `automatedBackup`, and often `os`. Set those as a
comma-separated list in `.env` (not secrets; they are public catalog codes):

```bash
VPS_PLAN_OPTION_CODES=option-linux,option-storage-local-2027-model1,option-auto-backup-2027-1-model1
```

Discover the codes for your plan from the public catalog (replace `US` with your
subsidiary):

```bash
curl -fsSL 'https://api.us.ovhcloud.com/1.0/order/catalog/public/vps?ovhSubsidiary=US' \
  | jq '.plans[] | select(.planCode=="vps-2027-model1") | .addonFamilies[]
      | select(.mandatory==true) | {name, addons}'
```

For `vps-2027-model1`, `option-storage-local-2027-model1` is the only storage
choice, and automated backup is either `option-auto-backup-2027-1-model1`
(standard / 1-day) or `option-auto-backup-2027-7-model1` (premium / 7-day).

**OVH API token permissions**

Create the AK/AS/CK as one token with the least rights that match your mode:

- `VPS_MODE=existing` (read an already-running VPS): allow `GET` on `/vps` and `/vps/*`.
- `VPS_MODE=create` (order and manage a new VPS): allow at least:
  - `GET` on `/me`, `/me/*`, `/vps`, `/vps/*`, `/order/*`
  - `POST` on `/me/*`, `/vps`, `/vps/*`, `/order/*`
  - `PUT` on `/vps/*`, `/order/*`
  - `DELETE` on `/order/*` (cart cleanup during ordering)

OVH token paths are not recursive from a parent route: `GET /me` only
authorizes that exact call. Create mode also needs `GET /me/payment/method`
(default payment lookup) and `POST /me/order/*/pay` (checkout), so include
`/me/*` for both `GET` and `POST`. Do not grant account-wide `/*` rights
unless you intentionally want a break-glass token. The OVH account must
already have a default payment method before create mode can place an order.
Keep `OVH_ENDPOINT` in `.env` aligned with the portal where you created the
token (`ovh-eu`, `ovh-ca`, `ovh-us`, and so on).

### Cloudflare DNS and R2

OpenTofu uses two different Cloudflare credential types:

1. A Cloudflare **API token** (`cloudflare-api-token`) for the Terraform/OpenTofu
   Cloudflare provider: DNS records, optional SSL zone setting, and R2 bucket
   creation in bootstrap.
2. Separate R2 **S3 API credentials** for OpenTofu remote state and restic
   backups. Those are not interchangeable with the Cloudflare API token.

| 1Password field | Purpose | How to create or find it |
| --- | --- | --- |
| `cloudflare-api-token` | OpenTofu Cloudflare provider auth | Cloudflare dashboard → My Profile → API Tokens → Create Token → Create Custom Token. |
| `cloudflare-dns-api-token` | Host Caddy ACME DNS-01 | Separate custom token with Zone → Zone → Read and Zone → DNS → Edit only. Do not reuse the OpenTofu token. |
| `cloudflare-account-id` | Account that owns the zone and R2 | Cloudflare dashboard → any domain or R2 overview → Account ID in the right sidebar. |
| `cloudflare-zone-id` | Zone that will host `opnform-hostname` | Cloudflare dashboard → the zone → Overview → Zone ID. |
| `opnform-hostname` | Public FQDN for the site | The hostname OpenTofu will point at the VPS, for example `forms.example.com`. It must live in the selected zone. |
| `caddy-email` | ACME contact email for Caddy | An operator email address used by the host Caddy TLS configuration. |
| `r2-account-id` | R2 account id used in S3 endpoints | Usually the same value as `cloudflare-account-id`. Shown under R2 → Overview → Account Details. |
| `r2-state-bucket` | Bucket name for OpenTofu state | Choose a globally unique bucket name. Bootstrap creates it in the EU jurisdiction (`eeur`) with `prevent_destroy`. |
| `r2-backup-bucket` | Bucket name for restic backups | A second unique bucket name. Bootstrap also creates this bucket with `prevent_destroy`. |
| `r2-state-access-key-id` | S3 Access Key ID for state | See R2 token timing below. |
| `r2-state-secret-access-key` | S3 Secret Access Key for state | Shown once when the R2 token is created. |
| `r2-backup-access-key-id` | S3 Access Key ID for backups | Create a second R2 token for backups. |
| `r2-backup-secret-access-key` | S3 Secret Access Key for backups | Shown once when the backup R2 token is created. |
| `restic-password` | Encryption password for restic | Generate a long random secret (`openssl rand -base64 48`). Losing it makes backups unrecoverable. |

**Cloudflare API token permissions** (`cloudflare-api-token`)

Create a custom token limited to the OpnForm account and zone:

| Permission | Access | Required? |
| --- | --- | --- |
| Zone → DNS → Edit | Read/write DNS records for `opnform-hostname` | Yes |
| Zone → Zone → Read | Resolve zone metadata | Recommended |
| Account → Workers R2 Storage → Edit | Create/list R2 buckets during `just bootstrap-*` | Yes |
| Zone → Zone Settings → Edit | Set SSL mode to `strict` | Only if you set `CLOUDFLARE_MANAGE_SSL_SETTING=true` in `.env` |

Resource scope: include only the Cloudflare account and the specific zone used
for OpnForm.

**Cloudflare DNS API token** (`cloudflare-dns-api-token`)

Used only by host Caddy for Let's Encrypt / ZeroSSL **DNS-01** challenges
(`tls { dns cloudflare ... }`). Scope it to the OpnForm zone with
Zone → Zone → Read and Zone → DNS → Edit. Keep it separate from
`cloudflare-api-token` so rotating OpenTofu credentials does not break
certificate renewal. Token problems break renewal; the origin IP lock does not.

**R2 S3 API token permissions and timing**

`bootstrap-init` through `bootstrap-apply` need only the Cloudflare API token.
R2 S3 credentials are required starting at `bootstrap-migrate`, for
`bootstrap-remote-init` in subsequent checkouts, and for every production
OpenTofu/restic operation.

Bucket-scoped tokens cannot be created until the buckets exist. Use one of
these approaches:

1. **Recommended for first deploy:** create two R2 API tokens with
   **Object Read & Write** and leave them applicable to all buckets. Put those
   values in 1Password before `just env`. After bootstrap, optionally rotate to
   bucket-scoped tokens and update `.env`.
2. **Least privilege later:** run bootstrap with temporary all-bucket tokens,
   then replace them with Object Read & Write tokens scoped only to the state
   and backup buckets.

| Token | Permission | Bucket scope |
| --- | --- | --- |
| State (`r2-state-*`) | Object Read & Write | All buckets initially, or the state bucket after bootstrap |
| Backup (`r2-backup-*`) | Object Read & Write | All buckets initially, or the backup bucket after bootstrap |

The bootstrap stack creates both buckets in the EU jurisdiction. Use the
jurisdiction-specific S3 endpoint shown with the credentials:
`https://<R2_ACCOUNT_ID>.eu.r2.cloudflarestorage.com`. The default endpoint
without `.eu` cannot access these buckets.

Prefer Account API tokens for long-lived automation; User API tokens inherit
the creating user's membership and become invalid if that user leaves the
account.

One R2 backup bucket holds two restic repositories:

- `…/<r2-backup-bucket>/tofu-state` — encrypted OpenTofu state snapshots
- `…/<r2-backup-bucket>/opnform` — application database and uploads backups

### SSH access

| 1Password field | Purpose | How to create or find it |
| --- | --- | --- |
| `deploy-ssh-public-key-path` | Absolute path to the deploy public key on the controller | Generate an ed25519 keypair for this deployment (`ssh-keygen -t ed25519 -f ~/.ssh/opnform-deploy -C opnform-deploy`). Store the public key path, for example `/Users/you/.ssh/opnform-deploy.pub`. |
| `deploy-ssh-private-key-path` | Absolute path to the matching private key | Same keypair's private key path. Ansible and `just ssh` use this key. Keep the private key only on the controller filesystem; do not paste the key material into 1Password unless your policy requires it. |
| `ssh-allowed-cidrs` | CIDRs allowed to reach SSH when UFW is enabled | Comma-separated CIDRs for operator networks, for example `203.0.113.10/32,198.51.100.0/24`. Required in new-VPS mode; wrong CIDRs can lock you out after the first Ansible run. After deploy, live UFW changes are manual (SSH or [OVH KVM console](#update-ssh-allowed-ips-ovh-kvm-console)); updating this field alone does not rewrite host rules in `existing` mode. |
| `ovh-ssh-password` | KVM/console break-glass password | Created automatically by `just env` or deploy when missing (not by `just ansible-check`). Used for local console login only; SSH password authentication stays disabled. Do not rotate casually — regenerating requires updating the host password again via deploy. |

In create mode, OpenTofu installs the public key for the image's default admin
(`debian` / `ubuntu`) and does not email an initial password
(`do_not_send_password = true`). Ansible later creates `DEPLOY_USER`, installs
the same public key for that user, sets `ovh-ssh-password` on `DEPLOY_USER` and
`ANSIBLE_SSH_USER` for OVH KVM console access, disables password/root SSH, and
(in create mode) enables UFW for `SSH_ALLOWED_CIDRS` plus ports 80/443.
After `just origin-lock-enable`, UFW `before.rules` reject non-Cloudflare
clients on 80/443 before those wide allow rules apply.

In existing mode, `ANSIBLE_SSH_USER` must already accept the private key and
have passwordless sudo. OpenTofu does not install SSH keys onto an existing
VPS.

### GitHub Container Registry

| 1Password field | Purpose | How to create or find it |
| --- | --- | --- |
| `ghcr-owner` | GHCR namespace | GitHub user or organization that owns the private packages, for example `my-org`. |
| `ghcr-push-username` | Username for image pushes | The GitHub username that owns the push PAT. |
| `ghcr-push-token` | PAT used by `just release` to push images | GitHub → Settings → Developer settings → Personal access tokens (classic). |
| `ghcr-pull-username` | Username for VPS image pulls | Often the same user, or a dedicated pull-only bot account. |
| `ghcr-pull-token` | PAT installed on the VPS for `docker pull` | A second classic PAT with read-only package scope. |
| `postgres-image` | Postgres image digest reference | Must be digest-pinned. See below. |
| `redis-image` | Redis image digest reference | Must be digest-pinned. See below. |
| `nginx-image` | Nginx image digest reference | Must be digest-pinned. See below. |

Create empty private packages named `opnform-api` and `opnform-client` (or let
the first push create them), then restrict package access to the deployment
accounts. Authorize classic PATs for organization SSO when the org enforces
SAML.

**Dependency images must be digest-pinned**

Ansible rejects floating tags. Store values that match
`<image>@sha256:<64-hex>`, for example:

```sh
docker buildx imagetools inspect postgres:16 --format '{{.Manifest.Digest}}'
# store: postgres:16@sha256:<digest>
docker buildx imagetools inspect redis:7 --format '{{.Manifest.Digest}}'
docker buildx imagetools inspect nginx:1 --format '{{.Manifest.Digest}}'
```

`just release` resolves digests only for the API and client images it publishes.
Postgres, Redis, and Nginx digests come from these 1Password fields as-is.

**GitHub PAT permissions**

GitHub Packages authentication requires a **classic** personal access token.
Fine-grained PATs are not sufficient for GHCR in this workflow.

| Token field | Classic scopes | Notes |
| --- | --- | --- |
| `ghcr-push-token` | `write:packages`, `read:packages` | `write:packages` is required to publish. Include `read:packages` so the same token can resolve existing tags/digests. |
| `ghcr-pull-token` | `read:packages` only | Used on the VPS. Do not grant write or delete scopes. |

If the packages are organization-owned, grant the push user Write (or Admin)
on each package and the pull user Read.

### Application secrets

Generate these once per deployment and never reuse values from another
environment.

| 1Password field | Purpose | How to create it |
| --- | --- | --- |
| `app-key` | Laravel `APP_KEY` | `echo "base64:$(openssl rand -base64 32)"`. Must keep the `base64:` prefix. |
| `jwt-secret` | JWT signing secret | `openssl rand -base64 48` or any long random string (40+ characters). |
| `front-api-secret` | Shared secret between Nuxt and Laravel | `openssl rand -base64 32`. |
| `database-password` | PostgreSQL password for `DB_USERNAME` | Long random password. |
| `redis-password` | Redis `requirepass` value | Long random password. |

Rotating `app-key` or `jwt-secret` after go-live invalidates encrypted data and
sessions; treat them as immutable for the life of the deployment unless you
have an explicit rotation plan.

### SMTP

| 1Password field | Purpose | How to create or find it |
| --- | --- | --- |
| `smtp-host` | SMTP server hostname | From your mail provider (Postmark, SES, Mailgun, local relay, and so on). |
| `smtp-port` | SMTP port | Usually `587` for STARTTLS. `.env.example` sets `MAIL_ENCRYPTION=tls`. |
| `smtp-username` | SMTP auth username | Provider credentials. |
| `smtp-password` | SMTP auth password or API secret | Provider credentials. Scope the credential to send-only if the provider supports it. |
| `smtp-from-address` | Envelope/from address | A verified sender/domain in the mail provider, for example `noreply@example.com`. |

Exact SMTP credential permissions depend on the provider. Prefer a
send-only key or SMTP user that cannot manage domains, webhooks, or account
billing.

### Bootstrap administrator

Used only while setup is open on the first release. Choose a strong password
even if OIDC will take over afterward.

| 1Password field | Purpose |
| --- | --- |
| `bootstrap-admin-name` | Display name for the first administrator |
| `bootstrap-admin-email` | Email for the first administrator |
| `bootstrap-admin-password` | Password for the first administrator |

### Google Sheets (optional)

Disabled by default (`GOOGLE_SHEETS_ENABLED=false`). When enabled, both OAuth
client fields are required and are injected into the API container env. The app
turns the Google Sheets integration on when those credentials are present.

| 1Password field | Purpose | How to create or find it |
| --- | --- | --- |
| `google-client-id` | Google OAuth Client ID | [Google Cloud Console](https://console.cloud.google.com/) → APIs & Services → Credentials → OAuth 2.0 Client ID (Web application). Enable the Google Drive and Google Sheets APIs. Add `https://<opnform-hostname>` as an authorized JavaScript origin. |
| `google-client-secret` | Google OAuth Client Secret | Shown with the OAuth client. Leave redirect URIs empty; OpnForm generates them from the hostname. |

See the [OAuth Integration Setup](https://docs.opnform.com/configuration/oauth-setup) guide for the full Google Cloud steps. After updating `.env`, apply with:

```sh
CONFIRM_PROD=opnform-prod just google-sheets
```

That re-renders `/opt/opnform/secrets/api.env` and recreates the API containers
and ingress. Ingress nginx re-resolves `api` and `ui` through Docker DNS, so a
stale upstream IP cannot survive a container recreate; the ingress bounce still
makes the cutover immediate. Full `just deploy` / `just release` also honor the
toggle when rendering `api.env`.

To disable, set `GOOGLE_SHEETS_ENABLED=false` and run `just google-sheets` again.

### Google Fonts (optional)

`just env` injects `GOOGLE_FONTS_API_KEY` from the `google-font-api-key`
1Password field. When that value is present, Ansible copies it into
`/opt/opnform/secrets/api.env`. The API enables the form font picker when the
key is set. This is an instance setting, not a plan entitlement. If the field
is missing, `just env` leaves the variable empty and warns.

| 1Password field | Purpose | How to create or find it |
| --- | --- | --- |
| `google-font-api-key` | Google Fonts Developer API key | [Google Cloud Console](https://console.cloud.google.com/) → APIs & Services → Credentials → API key. Enable the [Web Fonts Developer API](https://developers.google.com/fonts/docs/developer_api). Restrict the key to that API. |

After populating `GOOGLE_FONTS_API_KEY` in the local `.env`, deploy an existing
published release using its release ID:

```sh
CONFIRM_PROD=opnform-prod just deploy-release sha-<sha>
```

That re-renders `/opt/opnform/secrets/api.env` and applies the updated environment
to the API containers without rebuilding images. The API startup clears the
application cache, including font availability.

To disable, empty `GOOGLE_FONTS_API_KEY` in `.env` and deploy the release again.
Also empty or remove the 1Password field to keep future environment renders disabled.

### OIDC (optional but enabled by default)

`.env.example` sets `OIDC_ENABLED=true` and `OIDC_FORCE_LOGIN=true`. Leave both
enabled only after the IdP application exists and the callback URI is
registered. For a password-first bootstrap, set both to `false` in the
generated `.env` before the first release and configure SSO later in the UI.

| 1Password field | Purpose | How to create or find it |
| --- | --- | --- |
| `oidc-name` | Display name in OpnForm | For example `Company SSO`. |
| `oidc-slug` | URL slug for the connection | Lowercase slug such as `company-sso`. It appears in the callback path. |
| `oidc-domain` | Email domain used for IdP routing | For example `example.com`. |
| `oidc-issuer` | IdP issuer URL | Base issuer from the IdP; confirm `{issuer}/.well-known/openid-configuration` resolves. |
| `oidc-client-id` | OAuth/OIDC client ID | Created in the IdP application registration. |
| `oidc-client-secret` | OAuth/OIDC client secret | Created with the IdP application. |

**OIDC client permissions / settings**

Register a confidential web application in your IdP with:

- Grant type: Authorization Code
- Redirect / callback URI:
  `https://<opnform-hostname>/auth/<oidc-slug>/callback`
- Scopes: `openid`, `profile`, and `email` (matches `OIDC_SCOPES_JSON` in
  `.env.example`)
- Client authentication: client secret (store it in `oidc-client-secret`)

No IdP admin or directory-write scopes are required. If you use group-to-role
mappings later, configure the IdP to include a `groups` (or `group`) claim in
the ID token; the default bootstrap mapping list is empty.

After the first successful OIDC bootstrap, Ansible stores a least-privilege
automation token only on the VPS at
`/opt/opnform/secrets/oidc-automation-token`. Later deploys reconcile issuer,
mappings, and client secret using that token. Do not delete it.

## Local `.env` knobs

These values are not injected from 1Password (or are safe defaults in
`.env.example`). Review them after `just env`:

| Variable | Notes |
| --- | --- |
| `DEPLOYMENT_NAME` | Stable name. Every `CONFIRM_PROD=…` value must match it exactly. |
| `VPS_MODE` | `create` or `existing`. |
| `VPS_SERVICE_NAME` | Required when `VPS_MODE=existing` (OVH service name). |
| `VPS_DISPLAY_NAME` | Human-readable name for a newly created VPS. |
| `VPS_PLAN_OPTION_CODES` | Required for modern create-mode plans. Comma-separated mandatory cart option codes (`os`, `storage`, `automatedBackup`). |
| `OVH_ENDPOINT` | Must match the OVH API region used to create the token. |
| `ANSIBLE_SSH_USER` | First-login admin Ansible uses (`debian`, `ubuntu`, or an existing sudo user). |
| `DEPLOY_USER` | Service account Ansible creates (default `opnform`). |
| `SSH_PORT` | Must stay consistent with UFW and sshd after hardening. |
| `CLOUDFLARE_PROXIED` | Default `true`. With origin lockdown, clients must use the hostname via Cloudflare. |
| `CLOUDFLARE_MANAGE_IPV6_RECORD` | Default `true`. Creates the Cloudflare AAAA record from the OVH-reported VPS IPv6 address. Set to `false` if the VPS has no IPv6 address. |
| `CADDY_ORIGIN_LOCKDOWN` | Default `true`. App-layer Caddy `remote_ip` gate; direct origin peers get HTTP 403 when proxying is enabled. |
| `CLOUDFLARE_DNS_API_TOKEN` | Required. Caddy ACME DNS-01 token (Zone:Read + DNS:Edit). |
| `CLOUDFLARE_IP_SYNC_HEALTHCHECKS_URL` | Optional. Healthchecks.io-compatible ping URL for the IP sync timer. |
| `CLOUDFLARE_MANAGE_SSL_SETTING` | Default `false`. When `true`, OpenTofu sets the zone SSL mode to `strict`. |
| `OIDC_ENABLED` / `OIDC_FORCE_LOGIN` | See OIDC section. Force login disables password auth after an OIDC connection exists. |
| `OIDC_*_JSON` | Must remain valid JSON strings. |
| `GOOGLE_SHEETS_ENABLED` | Default `false`. When `true`, `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` are required; apply with `just google-sheets`. |
| `OPNFORM_DOCKER_SUBNET` / `OPNFORM_INGRESS_IP` | Must not collide with other Docker networks on the host. |
| `IMAGE_PLATFORM` | Default `linux/amd64`; must match the VPS architecture. |
| `BACKUP_*` | systemd timer schedule and restic retention. |
| `RELEASE_ID` / `OPNFORM_API_IMAGE` / `OPNFORM_CLIENT_IMAGE` | Filled by `just publish` / `just release`. Do not hand-edit floating tags. |

## Configure and provision

### Choose VPS mode

For a new VPS, set `VPS_MODE=create` and populate the OVH plan, mandatory plan
options (`VPS_PLAN_OPTION_CODES`), image ID, datacenter, and deployment SSH key
fields. OpenTofu creates the VPS with `prevent_destroy` and ignores later
`image_id` changes, so OpenTofu cannot reinstall it.

For an existing VPS, set `VPS_MODE=existing` and `VPS_SERVICE_NAME` to its OVH
service name. OpenTofu reads the VPS but never imports, destroys, or reinstalls
it. Requirements:

- Debian-family OS only (Debian 12/13 or Ubuntu 24.04/26.04).
- Native systemd Caddy v2 with a Caddyfile at `CADDY_CONFIG_PATH`.
- The OpnForm hostname must not already appear in unmanaged Caddy site files.
- Existing mode does not alter the global firewall by default.

`ANSIBLE_SSH_USER` is the existing sudo-capable login Ansible uses. New Ubuntu
VPS images normally use `ubuntu`; set `debian` for Debian or the appropriate
administrator account for an existing VPS. The automation creates the separate
`DEPLOY_USER` account for the service and future operations.

### OpenTofu bootstrap and production

For the first deployment, initialize the bootstrap stack with local state,
create the remote state and backup buckets from a reviewed plan, and then
migrate the bootstrap state to R2:

```sh
just bootstrap-init
just bootstrap-plan
just bootstrap-show
CONFIRM_PROD=opnform-prod just bootstrap-apply
CONFIRM_PROD=opnform-prod just bootstrap-migrate
just bootstrap-plan
just bootstrap-show
just init
just plan
just show-plan
CONFIRM_PROD=opnform-prod just apply
```

Replace `opnform-prod` with the `DEPLOYMENT_NAME` in `.env`. Do not apply
without reviewing the saved plan. `bootstrap-init` explicitly selects the
local backend because the R2 state bucket does not exist yet. `bootstrap-plan`
refuses to guess a backend if you skip initialization. `bootstrap-migrate`
backs up the local state, copies it to R2, verifies both bucket resources in
the remote state, and retains the ignored `terraform.tfstate.pre-migration-*`
backup under `infra/opentofu/bootstrap/` for recovery. The second bootstrap
plan verifies that the migrated backend produces no unexpected changes. Keep
the mode-`0600` backup until you have reviewed that plan; never commit it.

After migration, the checkout records that bootstrap uses R2. In a fresh
checkout or on another operator machine, initialize the existing bootstrap
state before planning changes:

```sh
just bootstrap-remote-init
just bootstrap-plan
just bootstrap-show
```

Do not run `bootstrap-init` again for an existing deployment: it is only for
the first local bootstrap. Use `bootstrap-remote-init` when the bootstrap state
already exists in R2. Every production plan first writes an encrypted R2 state
snapshot. On the first production plan, the state snapshot is skipped because
no production state exists yet; the encrypted restic repository is initialized
automatically before the first snapshot that has state to save.

Useful outputs after apply:

```sh
tofu -chdir=infra/opentofu/environments/production output
```

Note `vps_ipv4`, `opnform_url`, and `oidc_redirect_uri`.

### SSH host key and inventory

Ansible inventory sets `StrictHostKeyChecking=yes`. Trust the VPS host key
out-of-band before the first deploy:

```sh
just inventory
ssh-keyscan -p "$SSH_PORT" "<vps-ipv4>" >> ~/.ssh/known_hosts
just ssh
```

`just ssh` and the inventory connect as `ANSIBLE_SSH_USER`, not `DEPLOY_USER`.
`DEPLOY_USER` exists only after the first Ansible run. Before first deploy,
verify:

```sh
ssh -i "$SSH_PRIVATE_KEY_PATH" -p "$SSH_PORT" "$ANSIBLE_SSH_USER@<vps-ip>"
```

If `SSH_PRIVATE_KEY_PATH` is a `.pub` stub for the **1Password SSH agent**, unlock
1Password first and confirm a normal Terminal can sign with that key. Ansible
helpers prefer the agent socket at
`~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock` (or
`~/.1password/agent.sock`) when present. Approve the 1Password authorization
prompt when SSH/Ansible asks to use the key.

## First release

Greenfield deployment needs a published digest-pinned release. Do not run bare
`just deploy` until `RELEASE_ID`, `OPNFORM_API_IMAGE`, and
`OPNFORM_CLIENT_IMAGE` are set by publish/release.

From a **clean committed** worktree (dirty trees are refused). Run
`just doctor` first if you have not recently verified release tooling:

```sh
just doctor
CONFIRM_PROD=opnform-prod just release
```

That command:

1. Runs lint/tests (`npm run lint`, `api/vendor/bin/pest`).
2. Builds Linux AMD64 API and client images with Buildx.
3. Scans them with Trivy (fails on HIGH/CRITICAL).
4. Pushes to GHCR and writes `infra/.deploy/releases/sha-<40-char-commit>.env`.
5. Runs Ansible `site.yml` (host prep, Caddy, compose release, bootstrap).
6. Runs smoke checks against `https://$OPNFORM_HOSTNAME`.

The form footer version is the newest `vX.Y.Z` release tag from
[OpnForm/OpnForm](https://github.com/OpnForm/OpnForm) that is contained in
`infra/upstream-baseline`. With the current baseline that is `v2.5.0`. The
deploy id stays `sha-<fork commit>`. After upstream publishes `v2.6.0`, this
instance still shows `v2.5.0` until that tag is merged and a new image is
published. Compare the footer with upstream's tags to see how many releases
behind you are.

`https://$OPNFORM_HOSTNAME/v` returns both values as plain text (upstream
tag on the first line, `sha-<fork commit>` on the second). Use it to confirm
the running image without SSH.

To skip Pest while still running lint and refusing a dirty worktree (also
honored by `just release-check`, `just build`, and `just publish`):

```sh
SKIP_TESTS=1 CONFIRM_PROD=opnform-prod just release
```

Do not put `SKIP_TESTS=1` in `.env`; pass it on the command line for a
one-shot override.

Partial path if you want to separate publish from deploy:

```sh
just release-check
just publish
CONFIRM_PROD=opnform-prod just deploy-release sha-<40-character-commit>
```

Local release manifests under `infra/.deploy/releases/` are gitignored. Losing a
manifest means republishing that commit or rebuilding the digest file before
`deploy-release`.

If you still have manifests under the old repo-root `.deploy/releases/` path,
migrate them file-by-file (safe when `infra/.deploy/releases/` already has
newer publishes). Preserves modes and skips IDs that already exist at the
destination:

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

`release_manifest` still reads the legacy path when the new file is missing,
so existing release IDs keep working until you migrate. After verifying,
remove `.deploy/releases`. Publishing always writes to
`infra/.deploy/releases/` and never overwrites a legacy file.

### What “done” looks like

- During first bootstrap the site returns HTTP 503
  (“temporarily undergoing maintenance”) until admin/OIDC setup finishes.
- Later releases use a short maintenance window; the API container applies
  migrations at startup.
- After success, `just smoke` (also run automatically) should pass
  `/api/healthcheck` and `/login`.
- Public URL: `https://<OPNFORM_HOSTNAME>`. With Cloudflare proxying and Caddy
  origin lockdown, browsing the raw VPS IP returns HTTP 403 until the network
  origin lock is enabled; after `just origin-lock-enable`, direct origin TCP
  80/443 from non-Cloudflare addresses is reset instead.
- Register this callback URI in the identity provider when OIDC is enabled:

```text
https://<OPNFORM_HOSTNAME>/auth/<OIDC_SLUG>/callback
```

## Cloudflare network origin lock

Two layers protect the origin:

1. **App layer** (`CADDY_ORIGIN_LOCKDOWN`): Caddy `remote_ip` allowlist imported
   from `/var/lib/opnform-cloudflare-origin-firewall/caddy/opnform-cloudflare-gate.caddy`.
   Non-Cloudflare clients that reach Caddy get HTTP 403.
2. **Network layer** (`opnform-cloudflare-origin-firewall`): `ipset` + iptables
   (UFW `before.rules` when UFW is active, otherwise `INPUT`) allow TCP 80/443
   only from Cloudflare ranges. Non-Cloudflare clients get TCP reset. SSH is
   never touched.

Caddy uses **DNS-01** via `caddy-dns/cloudflare` and
`CLOUDFLARE_DNS_API_TOKEN`, so certificate renewal is outbound-only and does
not require inbound Let's Encrypt access. The custom binary pins both Caddy and
the Cloudflare plugin and verifies an architecture-specific SHA-256 before
installation. When either version changes, rebuild and review both `amd64` and
`arm64` binaries, then update the versions and checksums together in
`infra/ansible/roles/caddy/defaults/main.yml`.

### Rollout

Keep an independent key-only SSH session open. Prefer OVH KVM console available
before any reboot.

1. Deploy with DNS-01 Caddy and origin-lock assets installed (**firewall and
   sync timer remain disabled**). Direct origin access still works at the TCP
   layer; Caddy may already return HTTP 403 for non-Cloudflare clients when
   app-layer lockdown is on.
2. Confirm the hostname is orange-clouded. Verify TLS and login through
   Cloudflare (`just smoke` and browser auth flows).
3. Enable the network lock and run all four checks:

```sh
CONFIRM_PROD=opnform-prod just origin-lock-enable
just smoke
just origin-block-check
# SSH check is included in origin-block-check
just origin-lock-status
```

4. Install/run the synchronizer, then enable the timer:

```sh
CONFIRM_PROD=opnform-prod just origin-lock-sync-install
CONFIRM_PROD=opnform-prod just origin-lock-sync-run
CONFIRM_PROD=opnform-prod just origin-lock-sync-enable
```

5. Reboot only with console access available, then repeat smoke,
   `origin-block-check`, and SSH.

Immediate rollback of the network lock:

```sh
CONFIRM_PROD=opnform-prod just origin-lock-disable
```

### Range maintenance

- Daily timer fetches the Cloudflare API + `ips-v4` / `ips-v6`, cross-checks
  them, auto-applies **additions**, and stages **removals** as pending.
- Review `summary.json` / pending removals on the host, then:

```sh
CONFIRM_CLOUDFLARE_IP_ETAG='<pending-etag>' CONFIRM_PROD=opnform-prod just origin-lock-approve-removals
```

- Tracked fallbacks in
  `infra/ansible/roles/cloudflare_origin_lock/files/cloudflare-ips-*.txt`
  are bootstrap-only. Refresh with `just ips-refresh` (or `DRY_RUN=1 just
  ips-refresh`). Merging that change does **not** update the live VPS and does
  **not** approve pending removals.

### Failure modes

- A failed apply can leave the unit enabled with partial rules. Disable before
  further container/Caddy churn, reinstall/enable, and re-run the four checks.
- A nonzero exit does not mean nothing changed; inspect
  `just origin-lock-status` before retrying.
- Empty range files abort; the allowlist is never applied empty.
- Cloudflare shrinking ranges requires explicit ETag approval.
- ACME renewal failures are almost always DNS token scope/expiry, not the
  firewall.

## Day-two operations

```sh
just status
just logs
just ssh
just smoke
just releases
just origin-lock-status
CONFIRM_PROD=opnform-prod just google-sheets
CONFIRM_PROD=opnform-prod just backup
just backup-check
CONFIRM_PROD=opnform-prod just rollback sha-<40-character-commit>
CONFIRM_PROD=opnform-prod just restore <restic-snapshot-id>
```

Optional validation helpers: `just fmt-check`, `just validate`,
`just security-scan` (needs Checkov and Trivy), `just ansible-lint`,
`just ansible-syntax`, and `just ansible-check`.

### Update SSH-allowed IPs (OVH KVM console)

UFW SSH allow rules are applied only when `VPS_MODE=create`. After you switch
to `existing`, changing `ssh-allowed-cidrs` / `SSH_ALLOWED_CIDRS` and
redeploying does **not** update the live firewall. Ansible also only **adds**
CIDRs; it never removes stale ones. Keep the 1Password field accurate for
documentation and future create-mode runs, but manage live access on the host.

If you still have SSH from an allowed network, update UFW there and skip the
console. Use the OVH KVM console when your current public IP is not in
`SSH_ALLOWED_CIDRS` and you cannot reach the VPS over SSH.

1. Look up `ovh-ssh-password` in `tech-admin` / `opnform-secrets`. Confirm
   `SSH_PORT` from `.env` (default `22`).
2. In the [OVHcloud Control Panel](https://www.ovh.com/manager/), open
   **Bare Metal Cloud** → **Virtual private servers** → your VPS.
3. On **General information**, open the `…` menu next to the VPS name and
   choose **KVM** (opens in a browser popup; use **Open in a new window** if
   needed). See OVH’s
   [KVM console guide](https://help.ovhcloud.com/csm/en-gb-vps-use-kvm?id=kb_article_view&sysparm_article=KB0047769).
4. Log in locally as `DEPLOY_USER` (default `opnform`) or `ANSIBLE_SSH_USER`
   (default `ubuntu`) with `ovh-ssh-password`. SSH password auth stays
   disabled; this password is for console login only. Type a few characters
   first — the KVM keyboard layout may not match yours.
5. Add your current public IP (use `/32` for a single address), optionally
   remove the old rule, and confirm. Copy `scripts/infra/update_ufw.sh` to the
   VPS, then:

```sh
./update_ufw.sh add NEW.IP.ADDR.ESS
# optional: ./update_ufw.sh remove OLD.IP.ADDR.ESS
./update_ufw.sh list
```

Replace `22` with `SSH_PORT` if you changed it. Prefer allowing a stable
egress CIDR (office VPN, travel VPN, or jump host) instead of a single home
`/32` when your ISP rotates addresses often.
6. From your workstation, verify `just ssh` (or an equivalent key-based SSH
   session) works, then update `ssh-allowed-cidrs` in 1Password and re-run
   `just env` so the local `.env` matches.

If the console password is wrong or the OS login is broken, use OVH **rescue
mode** instead of KVM: boot rescue, mount the disk, fix UFW (or temporarily
`ufw disable`), then reboot back to the normal OS. Do not disable UFW longer
than needed, and do not leave SSH open to `0.0.0.0/0`.

### Rollback vs restore

- `just rollback sha-<40>` switches the VPS to a retained image bundle under
  `/opt/opnform/releases/`. It does **not** reverse database migrations or
  restore uploads.
- If a release fails after the first successful deploy, Ansible automatically
  restores the previous containers and the pre-release database/uploads
  snapshot when available.
- `just restore <snapshot-id>` restores an application restic snapshot
  (database dump + uploads). Snapshot id is a restic hex id or `latest`. It
  does not restore OpenTofu state or container images.
- Do not manually alter OpenTofu state or force-unlock it without confirming
  that no plan/apply is active.

### Commands that require `CONFIRM_PROD`

Must equal `DEPLOYMENT_NAME`:

- `bootstrap-apply`, `bootstrap-migrate`
- `apply`
- `release`, `deploy-release`, `deploy`
- `backup`, `rollback`, `restore`
- `origin-lock-install`, `origin-lock-enable`, `origin-lock-disable`
- `origin-lock-sync-install`, `origin-lock-sync-run`, `origin-lock-sync-enable`,
  `origin-lock-sync-disable`, `origin-lock-approve-removals`,
  `origin-lock-rollback-ranges`
- `google-sheets`

Plan, inventory, smoke, status, logs, backup-check, `origin-lock-status`,
`origin-block-check`, and `ips-refresh` do not require it.

## Security notes

- `.env`, generated inventories, local plans, state snapshots, and release
  manifests are ignored and use mode `0600` or stricter.
- No application secret is an OpenTofu input, output, or state value.
- Docker registry passwords are supplied through stdin; Ansible suppresses logs
  and diffs for every secret-bearing task.
- Caddy exposes only the loopback Docker ingress. With Cloudflare proxying
  enabled, the OpnForm site rejects direct-origin peers at the app layer
  (HTTP 403) while other Caddy sites retain their own policy.
- After `origin-lock-enable`, TCP 80/443 accept only Cloudflare source ranges
  (UFW before.rules or INPUT). Existing VPS mode does not alter the global
  firewall by default. New VPS mode enables UFW for administrative SSH CIDRs
  and ports 80/443; the origin lock tightens web ingress when enabled.
- Caddy data directories hold ACME certificates and must survive redeploys;
  do not wipe them casually.
- Molecule role tests (Podman) are optional and not required for production
  apply or release.

set dotenv-load
set shell := ["bash", "-euo", "pipefail", "-c"]

# List the available infrastructure commands.
default:
    @just --list

# Check controller prerequisites without contacting a provider or server.
doctor:
    @scripts/infra/doctor.sh

# Render .env from the tech-admin/opnform-secrets 1Password item (warns on missing fields).
env:
    @scripts/infra/render-env.sh

# Remove the generated local environment file after confirming its path.
env-clean:
    @scripts/infra/env-clean.sh

# Create or update the uv-managed Python environment and Ansible collections.
python-sync:
    @uv sync --project infra/ansible --locked
    @cd infra/ansible && uv run --locked -- ansible-galaxy collection install --requirements-file collections/requirements.yml --collections-path .collections

# Refresh uv.lock after intentionally editing Python dependency constraints.
python-lock:
    @uv lock --project infra/ansible

# Initialise the bootstrap stack with local state before creating the R2 buckets.
bootstrap-init:
    @scripts/infra/tofu.sh bootstrap init-local

# Initialise bootstrap state from R2 in a fresh checkout after migration.
bootstrap-remote-init:
    @scripts/infra/tofu.sh bootstrap init-remote

# Create and review the R2 bootstrap plan.
bootstrap-plan:
    @scripts/infra/tofu.sh bootstrap plan

# Show the saved R2 bootstrap plan.
bootstrap-show:
    @scripts/infra/tofu.sh bootstrap show

# Apply the reviewed R2 bootstrap plan.
bootstrap-apply:
    @scripts/infra/tofu.sh bootstrap apply

# Back up and migrate bootstrap state from local storage into the new R2 bucket.
bootstrap-migrate:
    @scripts/infra/tofu.sh bootstrap migrate

# Check OpenTofu formatting.
fmt-check:
    @scripts/infra/tofu.sh bootstrap fmt-check
    @scripts/infra/tofu.sh production fmt-check

# Validate all OpenTofu configurations.
validate:
    @scripts/infra/tofu.sh bootstrap validate
    @scripts/infra/tofu.sh production validate

# Run static OpenTofu security checks when installed.
security-scan:
    @scripts/infra/security-scan.sh

# Initialise the production OpenTofu backend.
init:
    @scripts/infra/tofu.sh production init

# Create a reviewed production plan artifact.
plan:
    @scripts/infra/tofu.sh production plan

# Show the saved production plan artifact.
show-plan:
    @scripts/infra/tofu.sh production show

# Save an encrypted pre-operation state snapshot to the backup bucket.
state-snapshot:
    @scripts/infra/tofu.sh production snapshot

# Apply only the saved production plan after an explicit confirmation.
apply:
    @scripts/infra/tofu.sh production apply

# Generate the ignored Ansible production inventory from OpenTofu outputs.
inventory:
    @scripts/infra/ansible.sh inventory

# Lint Ansible roles and playbooks.
ansible-lint:
    @scripts/infra/ansible.sh lint

# Check Ansible syntax.
ansible-syntax:
    @scripts/infra/ansible.sh syntax

# Run a no-change Ansible deployment check.
ansible-check:
    @scripts/infra/ansible.sh check

# Configure the VPS and deploy the release images supplied by the environment.
deploy:
    @scripts/infra/ansible.sh deploy

# Run DNS, TLS, application, and OIDC smoke checks.
smoke:
    @scripts/infra/smoke.sh

# Validate the current commit before building a release.
release-check:
    @scripts/infra/release.sh check

# Build immutable API and client images for the current commit.
build:
    @scripts/infra/release.sh build

# Push the current commit's immutable images to GHCR.
publish:
    @scripts/infra/release.sh publish

# Deploy an already-published release manifest: just deploy-release sha-<sha>.
deploy-release release:
    @scripts/infra/release.sh deploy {{ release }}

# Build, push, and deploy the current clean commit.
release:
    @scripts/infra/release.sh release

# List releases retained on the production VPS.
releases:
    @scripts/infra/ansible.sh releases

# Roll back to a retained release: just rollback sha-<sha>.
rollback release:
    @scripts/infra/release.sh rollback {{ release }}

# Show service status on the VPS.
status:
    @scripts/infra/ansible.sh status

# Stream application logs from the VPS.
logs:
    @scripts/infra/ansible.sh logs

# Open an SSH shell to the deployment user.
ssh:
    @scripts/infra/ansible.sh ssh

# Create an encrypted application backup now.
backup:
    @scripts/infra/ansible.sh backup

# Verify the latest encrypted backup can be read.
backup-check:
    @scripts/infra/ansible.sh backup-check

# Restore a restic snapshot: just restore <snapshot-id>.
restore snapshot:
    @scripts/infra/ansible.sh restore {{ snapshot }}

# Install Cloudflare origin-lock assets (firewall unit left disabled).
origin-lock-install:
    @scripts/infra/origin-lock.sh install

# Enable and verify the Cloudflare origin firewall.
origin-lock-enable:
    @scripts/infra/origin-lock.sh enable

# Disable the Cloudflare origin firewall and tear down rules.
origin-lock-disable:
    @scripts/infra/origin-lock.sh disable

# Show origin-lock and sync status on the VPS.
origin-lock-status:
    @scripts/infra/origin-lock.sh status

# Install the Cloudflare IP sync timer assets (timer left disabled).
origin-lock-sync-install:
    @scripts/infra/origin-lock.sh sync-install

# Run one manual Cloudflare IP sync with verification.
origin-lock-sync-run:
    @scripts/infra/origin-lock.sh sync-run

# Enable the daily Cloudflare IP sync timer.
origin-lock-sync-enable:
    @scripts/infra/origin-lock.sh sync-enable

# Disable the daily Cloudflare IP sync timer.
origin-lock-sync-disable:
    @scripts/infra/origin-lock.sh sync-disable

# Apply reviewed Cloudflare IP removals: CONFIRM_CLOUDFLARE_IP_ETAG=<etag> just origin-lock-approve-removals
origin-lock-approve-removals:
    @scripts/infra/origin-lock.sh approve-removals

# Restore the previous Cloudflare IP range generation on the VPS.
origin-lock-rollback-ranges:
    @scripts/infra/origin-lock.sh rollback-ranges

# From the workstation, prove direct origin 80/443 access is blocked.
origin-block-check:
    @scripts/infra/origin-lock.sh block-check

# Refresh tracked Cloudflare fallback snapshots in the repo (DRY_RUN=1 shows diff).
ips-refresh:
    @scripts/infra/origin-lock.sh ips-refresh

set dotenv-load
set shell := ["bash", "-euo", "pipefail", "-c"]

# List the available infrastructure commands.
default:
    @just --list

# Check controller prerequisites without contacting a provider or server.
doctor:
    @scripts/infra/doctor.sh

# Render .env from the tech-admin/opnform-secrets 1Password item.
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

# Initialise the local bootstrap stack that creates the R2 buckets.
bootstrap-init:
    @scripts/infra/tofu.sh bootstrap init

# Create and review the R2 bootstrap plan.
bootstrap-plan:
    @scripts/infra/tofu.sh bootstrap plan

# Show the saved R2 bootstrap plan.
bootstrap-show:
    @scripts/infra/tofu.sh bootstrap show

# Apply the reviewed R2 bootstrap plan.
bootstrap-apply:
    @scripts/infra/tofu.sh bootstrap apply

# Migrate bootstrap state from local storage into the newly-created R2 bucket.
bootstrap-migrate:
    @scripts/infra/tofu.sh bootstrap migrate

# Check OpenTofu formatting.
fmt-check:
    @scripts/infra/tofu.sh production fmt-check

# Validate all OpenTofu configurations.
validate:
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

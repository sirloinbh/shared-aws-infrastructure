# Shared AWS Infrastructure

The Terraform source repo for the infrastructure of the personal AWS account. It manages one production server that all the apps share: a 2 GB Lightsail `small_3_0` in the Seoul region (`bundle_id` and `instance_name` are set in `terraform.tfvars` since the 2026-11-15 resize, [operations doc](docs/operations.md) section 11). A reverse proxy on the server serves each app at `https://<app>.daysofme.com` (the app list is in `apps.json`). The server is set up as follows.

- Static IP, with one Route 53 A record per app and shared service
- Firewall: ports 22, 80, and 443 are open only to the allowed IPs
- Automatic snapshots: daily at 03:00 (Seoul time), AWS keeps the latest 7
- Monthly budget alert (`monthly_budget_usd`, default $20): 50% and 80% of actual spend, 100% of forecasted spend

Resources still carry the `workout-memo-*` prefix (`var.project`) because the server started as workout-memo's. That name is historical; do not rename it, because a new name replaces the Lightsail instance, static IP, and key pair.

`user-data.sh` sets up only the host baseline on the first boot: the time zone, 2GB of swap, Docker and Compose, and the Docker log limits. The apps, the shared proxy and certificates, the shared `.env`, and the timers are not in this repo.

```sh
cp terraform.tfvars.example terraform.tfvars   # enter personal values; excluded from git
cp state.tfbackend.example state.tfbackend     # state bucket name and profile; excluded from git
terraform init "-backend-config=state.tfbackend"
terraform plan "-out=deploy.tfplan"
terraform apply deploy.tfplan
```

- If the account of the current credentials differs from `expected_account_id`, the plan fails. This prevents applying with a company profile.
- `user_data` runs only on the first boot. Changing it does not recreate the existing instance (`ignore_changes`).
- The Terraform state lives in a versioned S3 bucket with a lock file (S3 backend, Terraform 1.10 or later). In a new account, create that bucket first ([operations doc](docs/operations.md) 3-2). `terraform.tfvars` and `state.tfbackend` are not stored in git; back them up outside the repo when you change them.
- The budget alert is not a spending cap.
- Terraform manages its own `terraform-*` IAM policies (`iam.tf`, `iam-policies/`), capped by a permissions boundary that only an administrator can change; the roles it creates carry a second boundary (#85). The one-time CloudShell bootstrap is `scripts/bootstrap-iam.sh` ([operations doc](docs/operations.md) section 1-2).

## Recovery

**The Lightsail snapshot is the recovery path for the whole server** (user decision 2026-11-21, #64). No script rebuilds the server from scratch: a new instance built from `user-data.sh` alone has Docker but no apps. To recover, build a new instance from the latest automatic snapshot and move the static IP to it ([operations doc](docs/operations.md) section 13). Database changes made after that snapshot come back from the off-server S3 dumps (each app repo's backup doc).

## Docs

- [Infrastructure operations](docs/operations.md): setup, apply, state management and recovery after losing it, server recovery from a snapshot, adding an SSH key, changing allowed IPs, alarms, teardown
- App deploys, rollbacks, auto-deploy, and DB backup restore: workout-memo `docs/deployment.md`
- Work instructions: [AGENTS.md](AGENTS.md), [AGENTS.project.md](AGENTS.project.md)

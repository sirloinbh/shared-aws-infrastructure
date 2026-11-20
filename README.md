# Shared AWS Infrastructure

The Terraform source repo for the infrastructure of the personal AWS account. It manages one production server that all the apps share: a 2 GB Lightsail `small_3_0` in the Seoul region (`bundle_id` and `instance_name` are set in `terraform.tfvars` since the 2026-11-15 resize, [operations doc](docs/operations.md) section 11). A reverse proxy on the server serves each app at `https://<app>.daysofme.com` (the app list is in `apps.json`). The server is set up as follows.

- Static IP, with one Route 53 A record per app and shared service
- Firewall: ports 22, 80, and 443 are open only to the allowed IPs
- Automatic snapshots: daily at 03:00 (Seoul time), AWS keeps the latest 7
- Monthly budget alert (`monthly_budget_usd`, default $20): 50% and 80% of actual spend, 100% of forecasted spend

Resources still carry the `workout-memo-*` prefix (`var.project`) because the server started as workout-memo's. That name is historical; do not rename it, because a new name replaces the Lightsail instance, static IP, and key pair.

`user-data.sh` initializes the server. It sets up the Docker and Compose install, 2GB of swap, the app repository clone, DB password generation, and a daily DB dump (kept for 14 days).

```sh
cp terraform.tfvars.example terraform.tfvars   # enter personal values; excluded from git
terraform init
terraform plan "-out=deploy.tfplan"
terraform apply deploy.tfplan
```

- If the account of the current credentials differs from `expected_account_id`, the plan fails. This prevents applying with a company profile.
- `user_data` runs only on the first boot. Changing it does not recreate the existing instance (`ignore_changes`).
- Terraform state and `terraform.tfvars` are not stored in git. There is no remote backend, so back them up outside the repo after each apply.
- The budget alert is not a spending cap.

## Docs

- [Infrastructure operations](docs/operations.md): setup, apply, state management and recovery after losing it, adding an SSH key, changing allowed IPs, alarms, teardown
- App deploys, rollbacks, auto-deploy, and DB backup restore: workout-memo `docs/deployment.md`
- Work instructions: [AGENTS.md](AGENTS.md), [AGENTS.project.md](AGENTS.project.md)

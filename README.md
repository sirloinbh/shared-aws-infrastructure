# Shared AWS Infrastructure

The Terraform source repo for the infrastructure of the personal AWS account. For now it manages one workout-memo production server: a Lightsail `micro_3_0` in the Seoul region, set up as follows.

- Static IP
- Firewall: ports 22 and 80 are open only to the allowed IPs
- Automatic snapshots: daily at 03:00 (Seoul time), AWS keeps the latest 7
- $10 monthly budget alert: 50% and 80% of actual spend, 100% of forecasted spend

`user-data.sh` initializes the server. It sets up the Docker and Compose install, 2GB of swap, the app repository clone, DB password generation, and a daily DB dump (kept for 14 days).

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

## Docs

- [Infrastructure operations](docs/operations.md): setup, apply, state management and recovery after losing it, adding an SSH key, changing allowed IPs, alarms, teardown
- App deploys, rollbacks, auto-deploy, and DB backup restore: workout-memo `docs/deployment.md`
- Work instructions: [AGENTS.md](AGENTS.md), [AGENTS.project.md](AGENTS.project.md)

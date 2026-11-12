# Shared AWS Infrastructure Project Instructions

These rules apply to this repo only. The common procedure is in [AGENTS.md](AGENTS.md); if the two files differ, this file wins.

## What this repo manages

- The workout-memo production server in the personal AWS account, Seoul region (`ap-northeast-2`): the Lightsail instance, the static IP and its attachment, the SSH key pair, the firewall, and the monthly budget alert. The setup and costs are in the [operations doc](docs/operations.md).
- Resource names use the `var.project` prefix (`workout-memo-*`). When another app is added, tell them apart by prefix.
- Each app repo manages its own deploys, rollbacks, auto-deploy, and DB backups (workout-memo `docs/deployment.md`).

## plan and apply

- Make real AWS changes **only within the scope the user asked for**. Create `terraform plan -out=<file>` with the personal account profile (`aws_profile`, `expected_account_id`), show the result to the user for confirmation, and then apply that plan file.
- If the plan has a replacement (`-/+`) or a deletion, do not apply; report the cause and the impact first. Recreating the static IP changes the public address.
- `user_data` is `ignore_changes`. A change does not reach the existing server, so make any needed change for the existing server with the app repo's deploy script.
- Raising the provider version saves the state in a new format that cannot be undone. Merge the version-change PR first, then apply.
- There is no remote backend. The state lives only in this folder on the PC that applied, so back it up outside the repo after each apply. If it is lost, follow the import procedure in the [operations doc](docs/operations.md).

## Versions

- The Terraform CLI and Action versions follow `versions.json` in `sirloinbh/project-standards`.
- The AWS provider is pinned by `versions.tf` and `.terraform.lock.hcl`. When you raise it, pick a version that is at least 14 days past its release, and record the hashes of both platforms with `terraform providers lock -platform=windows_amd64 -platform=linux_amd64`.

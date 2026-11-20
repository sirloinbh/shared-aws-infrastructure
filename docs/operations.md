# Infrastructure operations

This is the procedure for creating and managing one Lightsail server in the Seoul region of the personal AWS account with Terraform. App deploys, rollbacks, auto-deploy, and DB backup restore inside the server follow the app repo doc (workout-memo `docs/deployment.md`).

Run every command in this repo's folder. The profile name in the examples is `workout-personal`.

## Setup and costs

| Item | Value | Monthly cost (before tax, estimate) |
|---|---|---|
| Lightsail `micro_3_0`, Seoul | 1GB RAM, 40GB SSD, public IPv4, 2TB transfer, Ubuntu 24.04 | $7.00 |
| Static IP | While attached to the instance | $0 |
| Automatic snapshots | Daily at 03:00 (Seoul time), AWS keeps the latest 7, $0.05/GB-month by used size | under about $1 |
| DB dump | Daily at 03:30 (Seoul time), kept for 14 days in `/var/backups/workout` on the server (also included in the snapshots) | $0 |
| Off-server copy of the DB dump (#7) | S3 `sirloinbh-db-backups-<account ID>`, a daily dump and a row-count file per app, kept for 30 days (overwritten earlier versions also 30 days) | under $0.1 because the dumps are small (S3 Standard $0.025/GB-month, a few hundred upload requests a month) |
| study-log files (#53) | S3 `sirloinbh-study-log-files-<account ID>`, the original PDFs and photos of exercises; deleted or overwritten files stay recoverable for 30 days | a few cents for a few hundred MB (S3 Standard $0.025/GB-month), requests under $0.01 |
| Terraform state (#63) | S3 `sirloinbh-terraform-state-<account ID>`, the state of this repo and its lock file; earlier versions kept 90 days (the newest 20 always) | under $0.01 (a few hundred KB, a few hundred requests a month) |
| Reading the app keys (#8, #27) | SSM Parameter Store standard parameters, an IAM user | $0 |
| App subdomains (#33) | Route 53 A records `<app>.daysofme.com` in the zone the domain registration created. The domain and the zone are billed yearly (project-standards `docs/costs.md`) | about $0.50 for the zone, queries under $0.01 |
| Logs | Docker json-file, 10MB x 3 rotation per container | $0 |
| AWS Budgets | $10. Email at 50% and 80% of actual spend and 100% of forecasted spend | Free (a budget used only for alerts) |
| Total | | **about $7-8** (plus 10% VAT) |

- The budget alert does not stop spending. It covers the cost of the whole personal account.
- Cost sources: [Lightsail pricing](https://aws.amazon.com/lightsail/pricing/), [Budgets pricing](https://aws.amazon.com/aws-cost-management/aws-budgets/pricing/). The actual bill follows the prices and taxes at billing time.
- ECR and CloudWatch Logs are not used. S3 holds the DB dump copies and study-log's files. The user decided to keep an off-server copy instead of leaving a long-lived AWS key on the server (2026-10-27, project-standards#262), and to add a key for study-log's files because the server cannot use an IAM role (2026-11-17, #53). The server has four keys: one that can only upload to the backup bucket, one that can read only the app keys in SSM, one that can only write the certificate challenge record, and one that can only read, write and delete study-log's files (section 10).
- Each app is `https://<app>.daysofme.com`, only from allowed IPs. The shared reverse proxy on the server (project-standards#253) takes 80 and 443 and forwards each name to the app's web port on `127.0.0.1`, which is not open in the firewall.

## 1. One-time setup

### 1-1. Tools

Install the Terraform CLI and the AWS CLI. The Terraform version follows `versions.json` (`terraform.cli`) in `sirloinbh/project-standards`.

```powershell
winget install --id Hashicorp.Terraform --version <terraform.cli in versions.json> --exact
winget install --id Amazon.AWSCLI --exact
```

### 1-2. AWS credentials (do not create a root key)

Create an IAM user only for Terraform and use that user's access key.

1. Sign in to the console as the root account, then go to IAM → Users → Create user. Example name: `terraform-workout`. Do not give console access.
2. Permissions tab → Add permissions → Create inline policy → JSON (if you already created the user, replace the existing inline policy with this content. `BackupBucket` and `ServerUsers` were added in #7 and #8):
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       { "Sid": "Lightsail", "Effect": "Allow", "Action": "lightsail:*", "Resource": "*" },
       {
         "Sid": "BackupBucket",
         "Effect": "Allow",
         "Action": "s3:*",
         "Resource": ["arn:aws:s3:::sirloinbh-db-backups-*", "arn:aws:s3:::sirloinbh-db-backups-*/*"]
       },
       {
         "Sid": "ServerUsers",
         "Effect": "Allow",
         "Action": [
           "iam:CreateUser", "iam:DeleteUser", "iam:GetUser", "iam:UpdateUser", "iam:TagUser", "iam:UntagUser", "iam:ListUserTags",
           "iam:PutUserPolicy", "iam:GetUserPolicy", "iam:DeleteUserPolicy", "iam:ListUserPolicies",
           "iam:ListAttachedUserPolicies", "iam:ListAccessKeys", "iam:ListGroupsForUser"
         ],
         "Resource": "arn:aws:iam::*:user/sirloinbh-apps-*"
       },
       {
         "Sid": "Budgets",
         "Effect": "Allow",
         "Action": [
           "budgets:ViewBudget", "budgets:ModifyBudget",
           "budgets:ListTagsForResource", "budgets:TagResource", "budgets:UntagResource"
         ],
         "Resource": "*"
       }
     ]
   }
   ```
3. Route 53 (#33): IAM → Policies → Create policy → JSON, name it `terraform-route53-dns`, then on the user: Add permissions → Attach policies directly → that policy. It is a managed policy because all inline policies of one user share a 2,048-character limit, which the policy above nearly fills.
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "Route53Read",
         "Effect": "Allow",
         "Action": [
           "route53:ListHostedZones", "route53:GetHostedZone", "route53:ListTagsForResource",
           "route53:ListResourceRecordSets", "route53:GetChange"
         ],
         "Resource": "*"
       },
       {
         "Sid": "Route53Records",
         "Effect": "Allow",
         "Action": "route53:ChangeResourceRecordSets",
         "Resource": "arn:aws:route53:::hostedzone/*"
       }
     ]
   }
   ```
4. App files (#53): IAM → Policies → Create policy → JSON, name it `terraform-app-files`, then attach it to the user as in step 3. It is a separate managed policy for the same 2,048-character reason.
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "AppFileBuckets",
         "Effect": "Allow",
         "Action": "s3:*",
         "Resource": ["arn:aws:s3:::sirloinbh-study-log-files-*", "arn:aws:s3:::sirloinbh-study-log-files-*/*"]
       }
     ]
   }
   ```
4b. Server address (#69): IAM → Policies → Create policy → JSON, name it `terraform-server-ip`, and attach it to the user as in step 3. It lets Terraform manage the one parameter that holds the static IP, and lets the PC read it (project-standards `server-ip` and `server-ssh`). Without it `terraform apply` of the parameter fails with AccessDenied.
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "ServerIpParameter",
         "Effect": "Allow",
         "Action": ["ssm:PutParameter", "ssm:GetParameter", "ssm:DeleteParameter", "ssm:AddTagsToResource", "ssm:RemoveTagsFromResource", "ssm:ListTagsForResource"],
         "Resource": "arn:aws:ssm:ap-northeast-2:*:parameter/sirloinbh/shared/server-static-ip"
       },
       { "Sid": "ServerIpParameterRead", "Effect": "Allow", "Action": "ssm:DescribeParameters", "Resource": "*" }
     ]
   }
   ```
4c. Terraform state (#63): IAM → Policies → Create policy → JSON, name it `terraform-state`, and attach it to the user as in step 3. It lets Terraform create the state bucket and, after the move in section 3, read and write the state and its lock file. Without it the apply of the bucket fails with AccessDenied.
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "StateBucket",
         "Effect": "Allow",
         "Action": "s3:*",
         "Resource": ["arn:aws:s3:::sirloinbh-terraform-state-*", "arn:aws:s3:::sirloinbh-terraform-state-*/*"]
       }
     ]
   }
   ```
5. Security credentials tab → Create access key → use case "Command Line Interface (CLI)". In the description tag, write which PC it is for.
6. Register it under a name so it does not mix with the company profile, and check the account.
   ```powershell
   aws configure --profile workout-personal       # region ap-northeast-2
   aws sts get-caller-identity --profile workout-personal
   ```
   It is correct if `Arn` is `...:user/terraform-workout` and `Account` is the personal account.

Do not leave key values in the repo, chat, or issues. When the AWS CLI asks on its first run whether to install the skill and MCP server for AI agents, answer `n` if you do not need them.

### 1-3. SSH key

Create one per PC, only for this server. Keep the private key only on that PC.

```powershell
New-Item -ItemType Directory -Force "$HOME\.ssh" | Out-Null
ssh-keygen -t ed25519 -f "$HOME\.ssh\workout-memo-lightsail" -C "<pc-name>-workout-memo"
(Get-Content "$HOME\.ssh\workout-memo-lightsail.pub").Count   # must be 1
```

Paste the command as one line. If PowerShell breaks the line (a `>>` prompt appears), a line break enters the comment and the public key becomes two lines.

### 1-4. Variables file

Copy `terraform.tfvars.example` to `terraform.tfvars` and fill in the values. This file is excluded from git.

- `aws_profile`: the profile name from 1-2
- `expected_account_id`: the plan fails if the credentials belong to another account.
- `allowed_cidrs`: for example `["1.2.3.4/32"]`. Check your current public IP at `https://checkip.amazonaws.com`. If the server already exists, look at the current rules (`aws lightsail get-instance-port-states`) and match them.
- `budget_emails`

Copy `state.tfbackend.example` to `state.tfbackend` (also excluded from git) and fill in `bucket` (the `state_bucket` output, `sirloinbh-terraform-state-<account ID>`) and `profile` (the same as `aws_profile`). `terraform init` reads it to find the remote state (section 3).

When you create the files in PowerShell 5.1, write them as UTF-8 without BOM: `[IO.File]::WriteAllText(<path>, <content>, (New-Object Text.UTF8Encoding $false))`.

## 2. Apply the infrastructure

```powershell
terraform init "-backend-config=state.tfbackend"
terraform plan "-out=deploy.tfplan"   # the list of creates and changes, and the account check (without quotes, PowerShell splits `-out=` at the dot)
terraform apply deploy.tfplan
terraform output                      # static_ip, url, ssh, server_ip_parameter, backup_bucket, the server IAM user names
```

- What gets created: the SSH key registration, the instance, the static IP and its attachment, the firewall (ports 22 and 80 open only to the allowed IPs), the monthly budget alert, the S3 bucket for DB dump copies, the S3 bucket for the Terraform state (#63), and two IAM users for the server (section 10).
- If the plan has a replacement (`-/+`) or a deletion, do not apply. Recreating the static IP changes the public address.
- `user-data.sh` runs on the first boot. Lightsail runs user_data with `/bin/sh`, so an sh wrapper writes and runs a bash script (`/usr/local/sbin/workout-init`). It sets up 2GB of swap, the Docker and Compose install, the app repository clone, DB password generation (the server `.env`, which never leaves the server), the backup cron, and the auto-deploy timer. It takes a few minutes.
- `user_data` runs only on the first boot. Changing it does not recreate the existing instance (`ignore_changes`).

## 3. State management

- The state lives in the S3 bucket `sirloinbh-terraform-state-<account ID>` (`state_bucket` output) under the key `shared-aws-infrastructure/terraform.tfstate` (#63). `versions.tf` has the `backend "s3"` block; the bucket name and the profile come from the git-ignored `state.tfbackend` (1-4).
- Every plan and apply takes a lock: a `terraform.tfstate.tflock` object next to the state (`use_lockfile`, Terraform 1.10 or later). A second run at the same time stops with "Error acquiring the state lock". Wait for the other run. Only if a run was killed and no other run is going, remove the lock with `terraform force-unlock <lock ID from the error>`.
- Nothing has to be copied after an apply. Back up only `terraform.tfvars` and `state.tfbackend` outside the repo when you change them (they hold personal values, not the state). Avoid folders that sync to the cloud, such as OneDrive.
- On another PC: clone the repo, put `terraform.tfvars` and `state.tfbackend` in this folder, then `terraform init "-backend-config=state.tfbackend"` and `terraform plan` must show "No changes".
- Raising the provider version saves the state in a new format that cannot be undone. Merge the version-change PR first, then apply.

### 3-1. First move from the local state (once)

The bucket was created while the state was still local (#74). Do this once on the PC that has `terraform.tfstate`.

1. Check the tools and rights: `terraform version` is 1.10 or later, and the Terraform user has the `terraform-state` policy (1-2 step 4c).
2. Before pulling the backend change (main at the merge of #74, the state still local), apply the bucket if you have not yet, and read its name. If main on your PC already has the `backend "s3"` block, run this step in `git switch --detach <merge commit of #74>` and come back with `git switch main`:
   ```powershell
   terraform plan "-out=deploy.tfplan"   # the state bucket and its 6 settings; nothing to change or destroy
   terraform apply deploy.tfplan
   terraform output -raw state_bucket
   ```
3. Keep one last copy of the local state outside the repo, as before:
   ```powershell
   $bak = "$HOME\Backups\terraform-$(Get-Date -Format yyyyMMdd)-before-s3"
   New-Item -ItemType Directory -Force $bak | Out-Null
   Copy-Item terraform.tfstate*, terraform.tfvars $bak
   ```
4. Create `state.tfbackend` from the example (1-4) with the bucket name from step 2.
5. Pull main with the backend block and move the state. Answer `yes` when Terraform asks to copy the existing state to the new backend.
   ```powershell
   git pull --ff-only
   terraform init "-backend-config=state.tfbackend" -migrate-state
   terraform plan                        # must show "No changes"
   aws s3 ls "s3://<state_bucket>/shared-aws-infrastructure/" --profile workout-personal
   ```
6. Move `terraform.tfstate` and `terraform.tfstate.backup` out of this folder (the copy from step 3 stays). Terraform no longer reads them, and leaving them invites an old copy being used by mistake.

If `plan` in step 5 shows changes, do not apply; the state did not move as expected. Report it before doing anything else; the step 3 copy is the state from before the move.

### 3-2. Bootstrapping the bucket itself

The state bucket is managed by the same configuration whose state it holds. If it ever has to be created from nothing (a new account, or after it was deleted), the backend cannot be used yet: in a local, uncommitted copy remove the `backend "s3"` block, run `terraform init -reconfigure`, apply so the bucket exists, put the block back, and move the state as in 3-1 step 5.

### 3-3. Go back to an earlier state

Versioning keeps every earlier state for 90 days (`state_version_days`; the newest 20 are always kept). Use this when an apply wrote a wrong state or the state object was deleted.

```powershell
$b = "<state_bucket>"; $k = "shared-aws-infrastructure/terraform.tfstate"; $p = "--profile","workout-personal"
aws s3api list-object-versions @p --bucket $b --prefix $k --query "Versions[].{id:VersionId,time:LastModified,latest:IsLatest}" --output table
aws s3api get-object @p --bucket $b --key $k --version-id <id> restored.tfstate
terraform show restored.tfstate         # check it is the one you want
terraform state push -force restored.tfstate
terraform plan                          # compare with the real resources before any apply
```

`-force` is needed because the older copy has a lower serial. Delete `restored.tfstate` afterwards (it is git-ignored, but do not leave states lying around).

## 4. When you lose the state (recreate it with import)

First try an earlier version in the bucket (3-3). Use this section only when no usable version is left. If the bucket itself is gone, recreate it first (3-2), with the import file below in the same local run.

If you plan without a state, Terraform tries to create every resource anew. Do not apply as is; import the existing resources instead.

### 4-1. Check the resources

```powershell
$p = "--profile","workout-personal"
aws lightsail get-instances @p --query "instances[].{name:name,state:state.name,key:sshKeyName}" --output table
aws lightsail get-static-ips @p --query "staticIps[].{name:name,attachedTo:attachedTo}" --output table
aws lightsail get-key-pairs @p --query "keyPairs[].name" --output table
aws lightsail get-instance-port-states @p --instance-name workout-memo-app --output table
```

### 4-2. Whether each resource can be imported

| Resource | import | Handling |
|---|---|---|
| `aws_lightsail_instance.app` | Possible (name) | import |
| `aws_lightsail_static_ip.app` | Possible (name, provider v6.8.0 or later) | import |
| `aws_lightsail_static_ip_attachment.app` | Possible (static IP name, v6.10.0 or later) | import |
| `aws_budgets_budget.monthly` | Possible (`account ID:name`) | import |
| `aws_lightsail_key_pair.deploy` | Not possible | Delete the existing key pair in the console and create a new one with apply |
| `aws_lightsail_instance_public_ports.app` | Not possible | apply overwrites it with the same rules |
| `terraform_data.account_guard` | Not applicable | apply creates it anew (nothing is created in AWS) |
| `aws_s3_bucket.backups` and its 6 bucket settings (public access block, ownership, encryption, versioning, lifecycle, policy) | Possible (bucket name) | import. Do not create it anew, because deleting the bucket also deletes the copies |
| `aws_s3_bucket.study_log_files` and its 6 bucket settings (public access block, ownership, encryption, versioning, lifecycle, policy) | Possible (bucket name) | import. Do not create it anew, because deleting the bucket also deletes the files |
| `aws_s3_bucket.terraform_state` and its 6 bucket settings (public access block, ownership, encryption, versioning, lifecycle, policy) | Possible (bucket name) | import. Do not create it anew; it has `prevent_destroy` and holds every earlier state |
| `aws_iam_user.*`, `aws_iam_user_policy.*` | Possible (user name, `user:policy name`) | import |

### 4-3. Procedure

1. Create an import file that you will not commit, and make git ignore it in this clone only.
   ```powershell
   Add-Content .git\info\exclude "imports.local.tf"
   ```
   `imports.local.tf`:
   ```hcl
   import {
     to = aws_lightsail_instance.app
     id = "${var.project}-app"
   }
   import {
     to = aws_lightsail_static_ip.app
     id = "${var.project}-ip"
   }
   import {
     to = aws_lightsail_static_ip_attachment.app
     id = "${var.project}-ip"
   }
   import {
     to = aws_budgets_budget.monthly
     id = "${var.expected_account_id}:${var.project}-monthly"
   }
   ```
2. Run `terraform init "-backend-config=state.tfbackend"` and `terraform plan "-out=import.tfplan"`. The expected result is `4 to import, 3 to add, 0 to change, 0 to destroy`. If it differs, do not apply.
3. In the Lightsail console, go to Account → SSH keys and delete `workout-memo-deploy` in the Seoul region. The running instance is not affected.
4. After `terraform apply import.tfplan`, check that `terraform plan` shows "No changes".
5. Delete `imports.local.tf` and `import.tfplan`.
6. The new SSH key is not on the server yet. Add it to the server's `authorized_keys` with section 5.

## 5. Add a new PC's SSH key to the server

If you can connect with an existing key, add it to `authorized_keys` from that PC. If you lost the existing key, briefly allow Lightsail browser SSH and add it that way.

1. Console → Instance → Networking → edit the SSH (22) rule → check **Allow Lightsail browser SSH** → Save.
2. Run this from the Connect tab, Connect using SSH (two `>` characters):
   ```bash
   echo '<new public key, one line>' >> ~/.ssh/authorized_keys
   tail -n 2 ~/.ssh/authorized_keys
   ```
3. Edit the SSH rule again → uncheck **Allow Lightsail browser SSH** → Save. This setting does not show up in the Terraform plan, so check it yourself.
   ```powershell
   aws lightsail get-instance-port-states --profile workout-personal --instance-name workout-memo-app --query "portStates[].{port:fromPort,aliases:join(',',cidrListAliases)}" --output table   # aliases must be empty
   ```
4. On the first connection, compare the server fingerprint it shows with the AWS value, then answer `yes`.
   ```powershell
   aws lightsail get-instance-access-details --profile workout-personal --instance-name workout-memo-app --protocol ssh --query "accessDetails.hostKeys[].{alg:algorithm,sha256:fingerprintSHA256}" --output table
   ssh -i "$HOME\.ssh\workout-memo-lightsail" ubuntu@<static_ip> "hostname; uptime"
   ```

## 6. Connecting

The server's static IP is also stored in the SSM parameter `/sirloinbh/shared/server-static-ip` (a plain String, #69; `terraform output server_ip_parameter`). Tools read it from there: `aws ssm get-parameter --name /sirloinbh/shared/server-static-ip --query Parameter.Value --output text --profile workout-personal --region ap-northeast-2`. project-standards has `server-ip` and `server-ssh` for this, so nobody types the address by hand. If the address changes (a recreated static IP), `terraform apply` updates the parameter in the same run.

- **Browser**: `http://<static_ip>`. It opens only from the allowed IPs.
- **SSH**: `ssh -i ~/.ssh/workout-memo-lightsail ubuntu@<static_ip>`
- **SSH tunnel** (encrypted transport): run `ssh -i ~/.ssh/workout-memo-lightsail -L 8101:127.0.0.1:8101 ubuntu@<static_ip>`, then open `http://localhost:8101`. Use it when the shared proxy (`https://workout-memo.daysofme.com`) is down.
- **Do not use the Lightsail console's "Connect using SSH" (browser SSH).** It adds the `lightsail-connect` and `lightsail-connect-ipv6` ranges to port 22, which opens SSH beyond `allowed_cidrs`, and the next `terraform plan` then wants to replace the firewall. If they appear, remove them without Terraform: re-send the current rules with `aws lightsail put-instance-public-ports` and leave out `cidrListAliases`, then confirm `terraform plan` reports "No changes" (#43).

## 7. Change the allowed IPs

Add or remove entries in `allowed_cidrs` in `terraform.tfvars`, then run plan and apply. Only the firewall rules change, and the instance stays as it is. Opening to everyone (`/0`) is rejected by variable validation.

## 8. Alarms (optional)

The Terraform AWS provider has no resource for Lightsail metric alarms. Create them with the CLI if you need them. Each alarm costs about $0.10 a month, and an email contact works only after you approve the AWS confirmation email.

```powershell
aws lightsail create-contact-method --profile workout-personal --protocol Email --contact-endpoint <email>
aws lightsail put-alarm --profile workout-personal --alarm-name workout-memo-status --monitored-resource-name workout-memo-app --metric-name StatusCheckFailed --comparison-operator GreaterThanOrEqualToThreshold --threshold 1 --evaluation-periods 2 --notification-enabled --contact-protocols Email
```

## 9. Teardown

Running `terraform destroy` deletes the instance, static IP, firewall, and budget, and the DB and dumps inside the server go with them. Bring the backups you need to your PC first (the app repo doc). Automatic snapshots can remain after the instance is deleted and may keep costing money, so check them in the Lightsail console.

The Terraform state bucket has `prevent_destroy` (#63), so `terraform destroy` stops with an error while it is in the configuration. For a full teardown, first remove that line in a local, uncommitted copy. Also move the state back to a local file first (remove the `backend` block in the same copy, then `terraform init -migrate-state`), or the destroy deletes the bucket that holds the state it is writing to.

## 10. Creating the server keys (#7, #8)

You cannot attach an IAM role to the server, so the server needs access keys to use AWS. Terraform does not create the keys (so that no secret key stays in the state). Create them in the console after apply.

All apps on the server share these users, so they are named `sirloinbh-apps-*`, not after a specific app (project-standards ADR-0010). On 2026-10-29 they were first created as `workout-memo-*` and renamed the same day (`iam:UpdateUser`, plan `2 to add, 2 to change, 2 to destroy`: the users are renamed in place and the inline policies are attached again). While renaming, the `Resource` of `ServerUsers` in 1-2 must contain both the old and the new names.

| IAM user (`terraform output`) | What it can do | Keys in the server's shared file `/opt/project-standards/.env` |
|---|---|---|
| `sirloinbh-apps-backup-uploader` | Only upload files to the backup bucket (no read, list, or delete) | `BACKUP_S3_BUCKET` (= the `backup_bucket` output value), `BACKUP_AWS_ACCESS_KEY_ID`, `BACKUP_AWS_SECRET_ACCESS_KEY` |
| `sirloinbh-apps-certbot` | Only write the `_acme-challenge.<root_domain>` TXT record in the domain's hosted zone (#33, project-standards ADR-0012). It cannot change any other record | `CERTBOT_AWS_ACCESS_KEY_ID`, `CERTBOT_AWS_SECRET_ACCESS_KEY` (read by `cert.sh` of the server reverse proxy, project-standards `docs/server-proxy.md`) |
| `sirloinbh-apps-study-log-files` (#53) | Only get, put and delete objects in the study-log files bucket, and list its keys so a missing file reads as not found. It cannot change the bucket or remove earlier versions | Not in the shared file: only study-log uses it. Put `FILE_BUCKET` (= the `study_log_files_bucket` output value), `AWS_REGION=ap-northeast-2`, `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` in study-log's server `.env` (`/opt/study-log/.env`), which its compose file passes to the API |
| `sirloinbh-apps-secrets-reader` | Only read (`ssm:GetParameter`) SSM parameters under `/sirloinbh/shared/` and `/sirloinbh/<app>/` for the apps in `local.secret_apps` (`registry.tf`, project-standards ADR-0014) | `SECRETS_AWS_ACCESS_KEY_ID`, `SECRETS_AWS_SECRET_ACCESS_KEY` (read by every app whose `.env.example` tags a key with `@ssm=`, and by apps that use the Claude API) |

1. Console → IAM → Users → the user above → Security credentials → Create access key → use case "Application running outside AWS". Write "lightsail-server" in the description tag.
2. Connect to the server and put the keys above in one place, the shared file `/opt/project-standards/.env`. Do not put them in each app. Type the values only on the server and do not leave them in chat or docs. Create the file once:
   ```bash
   sudo install -d -o ubuntu -g ubuntu -m 700 /opt/project-standards
   install -m 600 /dev/null /opt/project-standards/.env
   ```
   For an app's deploy script to read this file, the sync PR from project-standards#266 must be merged into that app.
3. Backup: run `sudo bash /opt/<app>/deploy/install-backup.sh`, then `bash /opt/<app>/deploy/backup.sh dump`, and check that "uploaded ... to s3://..." appears.
4. App keys: create the SSM parameter from your PC with `node tools/app-secrets.mjs set <parameter>` (project-standards; without a parameter it stores the Claude key at `/sirloinbh/shared/anthropic-api-key`), then check on the server that `bash /opt/<app>/deploy/ssm-get.sh <parameter> > /dev/null && echo ok` prints `ok` (the value is not printed).
5. To change a key, create a new key, fix `.env`, then deactivate and delete the old key. If a server key leaks, delete this user's keys and replace every app key in SSM too.

## 11. Resize the server (from a snapshot)

Lightsail cannot change a running instance's plan. Changing `bundle_id` alone makes Terraform replace the instance with a blank Ubuntu one built from `user-data.sh`, and the DB on it is lost. Resize by building a new instance from a snapshot, then point Terraform at it. Done on 2026-11-15 from 1 GB (`micro_3_0`) to 2 GB (`small_3_0`) (#38, project-standards#564).

1. Note the time. The state bucket keeps the state from before the resize, and 3-3 brings it back if a step below goes wrong.
2. Snapshot: `aws lightsail create-instance-snapshot --instance-name <old> --instance-snapshot-name <old>-resize-<date>`, and wait until `get-instance-snapshot` says `available` (about 3 minutes for 1 GB). The app keeps running.
3. New instance with a **new name** (two instances cannot share one): `aws lightsail create-instances-from-snapshot --instance-names <new> --availability-zone ap-northeast-2a --instance-snapshot-name <snapshot> --bundle-id <bundle> --key-pair-name workout-memo-deploy --ip-address-type ipv4 --add-ons 'addOnType=AutoSnapshot,autoSnapshotAddOnRequest={snapshotTimeOfDay=18:00}' --tags key=Project,value=workout-memo`.
4. As soon as it exists, close the default firewall (it opens 22 and 80 to everyone): `aws lightsail put-instance-public-ports --instance-name <new> --port-infos file://ports.json`, with 22, 80, and 443 limited to `allowed_cidrs` (build the file from `terraform output -json allowed_cidrs`).
5. Move the static IP: `aws lightsail attach-static-ip --static-ip-name workout-memo-ip --instance-name <new>`. It detaches from the old instance in the same call. The containers start on their own (`restart: unless-stopped`); the proxy answers 502 for about 10 seconds until they are up.
6. Check `https://<app>.<root_domain>/api/health`, then stop the old instance (`aws lightsail stop-instance`) so its timers do not deploy, back up, or ping health checks twice.
7. Terraform: set `instance_name = "<new>"` and `bundle_id = "<bundle>"` in `terraform.tfvars`, then
   ```bash
   terraform state rm aws_lightsail_instance.app aws_lightsail_static_ip_attachment.app aws_lightsail_instance_public_ports.app
   terraform import aws_lightsail_instance.app <new>
   terraform import aws_lightsail_static_ip_attachment.app workout-memo-ip
   terraform plan    # must be 1 to add (the firewall rule, same values), 0 to change, 0 to destroy
   terraform apply
   ```
   `aws_lightsail_instance_public_ports` cannot be imported, so apply adds it again with the same rules.
8. After about a week without problems, delete the stopped old instance and the manual snapshot (`aws lightsail delete-instance`, `delete-instance-snapshot`). The old instance's automatic snapshots stay until deleted and cost money.

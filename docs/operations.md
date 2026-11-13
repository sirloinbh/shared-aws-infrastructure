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
| Reading the shared Claude API key (#8) | One SSM Parameter Store standard parameter, an IAM user | $0 |
| Logs | Docker json-file, 10MB x 3 rotation per container | $0 |
| AWS Budgets | $10. Email at 50% and 80% of actual spend and 100% of forecasted spend | Free (a budget used only for alerts) |
| Total | | **about $7-8** (plus 10% VAT) |

- The budget alert does not stop spending. It covers the cost of the whole personal account.
- Cost sources: [Lightsail pricing](https://aws.amazon.com/lightsail/pricing/), [Budgets pricing](https://aws.amazon.com/aws-cost-management/aws-budgets/pricing/). The actual bill follows the prices and taxes at billing time.
- ECR and CloudWatch Logs are not used. S3 is used only for the DB dump copies. The user decided to keep an off-server copy instead of leaving a long-lived AWS key on the server (2026-10-27, project-standards#262). The server has only two keys: one that can only upload to the bucket and one that can read only the Claude key (section 10).
- There is no domain, so access is over HTTP. The IP restriction applies, but the transport is not encrypted. On public Wi-Fi, use an SSH tunnel (section 6).

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
3. Security credentials tab → Create access key → use case "Command Line Interface (CLI)". In the description tag, write which PC it is for.
4. Register it under a name so it does not mix with the company profile, and check the account.
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

When you create the file in PowerShell 5.1, write it as UTF-8 without BOM: `[IO.File]::WriteAllText(<path>, <content>, (New-Object Text.UTF8Encoding $false))`.

## 2. Apply the infrastructure

```powershell
terraform init
terraform plan "-out=deploy.tfplan"   # the list of creates and changes, and the account check (without quotes, PowerShell splits `-out=` at the dot)
terraform apply deploy.tfplan
terraform output                      # static_ip, url, ssh, backup_bucket, the server IAM user names
```

- What gets created: the SSH key registration, the instance, the static IP and its attachment, the firewall (ports 22 and 80 open only to the allowed IPs), the monthly budget alert, the S3 bucket for DB dump copies, and two IAM users for the server (section 10).
- If the plan has a replacement (`-/+`) or a deletion, do not apply. Recreating the static IP changes the public address.
- `user-data.sh` runs on the first boot. Lightsail runs user_data with `/bin/sh`, so an sh wrapper writes and runs a bash script (`/usr/local/sbin/workout-init`). It sets up 2GB of swap, the Docker and Compose install, the app repository clone, DB password generation (the server `.env`, which never leaves the server), the backup cron, and the auto-deploy timer. It takes a few minutes.
- `user_data` runs only on the first boot. Changing it does not recreate the existing instance (`ignore_changes`).

## 3. State management

- There is no remote backend (S3 or similar). The state (`terraform.tfstate`) lives only in this folder on the PC that applied, and it is excluded from git.
- After each apply, back up the state and `terraform.tfvars` outside the repo. Avoid folders that sync to the cloud, such as OneDrive.
  ```powershell
  $bak = "$HOME\Backups\terraform-$(Get-Date -Format yyyyMMdd)"
  New-Item -ItemType Directory -Force $bak | Out-Null
  Copy-Item terraform.tfstate*, terraform.tfvars $bak
  ```
- To move to another PC, copy the backed-up files into this folder on the new PC and check for "No changes" with `terraform init` and `terraform plan`.
- Raising the provider version saves the state in a new format that cannot be undone. Merge the version-change PR first, then apply.

## 4. When you lose the state (recreate it with import)

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
| `aws_s3_bucket.backups` and its 5 bucket settings | Possible (bucket name) | import. Do not create it anew, because deleting the bucket also deletes the copies |
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
2. Run `terraform init` and `terraform plan "-out=import.tfplan"`. The expected result is `4 to import, 3 to add, 0 to change, 0 to destroy`. If it differs, do not apply.
3. In the Lightsail console, go to Account → SSH keys and delete `workout-memo-deploy` in the Seoul region. The running instance is not affected.
4. After `terraform apply import.tfplan`, check that `terraform plan` shows "No changes".
5. Delete `imports.local.tf` and `import.tfplan`, and back up the state as in section 3.
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

- **Browser**: `http://<static_ip>`. It opens only from the allowed IPs.
- **SSH**: `ssh -i ~/.ssh/workout-memo-lightsail ubuntu@<static_ip>`
- **SSH tunnel** (encrypted transport): run `ssh -i ~/.ssh/workout-memo-lightsail -L 8101:127.0.0.1:80 ubuntu@<static_ip>`, then open `http://localhost:8101`.

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

## 10. Creating the server keys (#7, #8)

You cannot attach an IAM role to the server, so the server needs access keys to use AWS. Terraform does not create the keys (so that no secret key stays in the state). Create them in the console after apply.

All apps on the server share the two users, so they are named `sirloinbh-apps-*`, not after a specific app (project-standards ADR-0010). On 2026-10-29 they were first created as `workout-memo-*` and renamed the same day (`iam:UpdateUser`, plan `2 to add, 2 to change, 2 to destroy`: the users are renamed in place and the inline policies are attached again). While renaming, the `Resource` of `ServerUsers` in 1-2 must contain both the old and the new names.

| IAM user (`terraform output`) | What it can do | Keys in the server's shared file `/opt/project-standards/.env` |
|---|---|---|
| `sirloinbh-apps-backup-uploader` | Only upload files to the backup bucket (no read, list, or delete) | `BACKUP_S3_BUCKET` (= the `backup_bucket` output value), `BACKUP_AWS_ACCESS_KEY_ID`, `BACKUP_AWS_SECRET_ACCESS_KEY` |
| `sirloinbh-apps-secrets-reader` | Only read the one SSM parameter `/sirloinbh/anthropic-api-key` | `SECRETS_AWS_ACCESS_KEY_ID`, `SECRETS_AWS_SECRET_ACCESS_KEY` (read by the apps that use the Claude API, for now study-log) |

1. Console → IAM → Users → the user above → Security credentials → Create access key → use case "Application running outside AWS". Write "lightsail-server" in the description tag.
2. Connect to the server and put the keys above in one place, the shared file `/opt/project-standards/.env`. Do not put them in each app. Type the values only on the server and do not leave them in chat or docs. Create the file once:
   ```bash
   sudo install -d -o ubuntu -g ubuntu -m 700 /opt/project-standards
   install -m 600 /dev/null /opt/project-standards/.env
   ```
   For an app's deploy script to read this file, the sync PR from project-standards#266 must be merged into that app.
3. Backup: run `sudo bash /opt/<app>/deploy/install-backup.sh`, then `bash /opt/<app>/deploy/backup.sh dump`, and check that "uploaded ... to s3://..." appears.
4. Claude key: create the SSM parameter from your PC with `node tools/app-secrets.mjs set` (project-standards), then check on the server that `bash /opt/study-log/deploy/ssm-get.sh /sirloinbh/anthropic-api-key > /dev/null && echo ok` prints `ok` (the value is not printed).
5. To change a key, create a new key, fix `.env`, then deactivate and delete the old key. If a server key leaks, delete this user's keys and replace the Claude API key too.

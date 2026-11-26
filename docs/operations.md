# Infrastructure operations

This is the procedure for creating and managing one Lightsail server in the Seoul region of the personal AWS account with Terraform. App deploys, rollbacks, auto-deploy, and DB backup restore inside the server follow the app repo doc (workout-memo `docs/deployment.md`).

Run every command in this repo's folder. The profile name in the examples is `workout-personal`.

## Setup and costs

| Item | Value | Monthly cost (before tax, estimate) |
|---|---|---|
| Lightsail `small_3_0`, Seoul (resized from `micro_3_0` on 2026-11-15, section 11) | 2GB RAM, 60GB SSD, public IPv4, 3TB transfer, Ubuntu 24.04 | $12.00 |
| Static IP | While attached to the instance | $0 |
| Automatic snapshots | Daily at 03:00 (Seoul time), AWS keeps the latest 7, $0.05/GB-month by used size | about $1-2 |
| DB dump | Daily at 03:30 (Seoul time), kept for 14 days in `/var/backups/workout` on the server (also included in the snapshots) | $0 |
| Off-server copy of the DB dump (#7) | S3 `sirloinbh-db-backups-<account ID>`, a daily dump and a row-count file per app, kept for 30 days (overwritten earlier versions also 30 days) | under $0.1 because the dumps are small (S3 Standard $0.025/GB-month, a few hundred upload requests a month) |
| study-log files (#53) | S3 `sirloinbh-study-log-files-<account ID>`, the original PDFs and photos of exercises; deleted or overwritten files stay recoverable for 30 days | a few cents for a few hundred MB (S3 Standard $0.025/GB-month), requests under $0.01 |
| Terraform state (#63) | S3 `sirloinbh-terraform-state-<account ID>`, the state of this repo and its lock file; earlier versions kept 90 days (the newest 20 always) | under $0.01 (a few hundred KB, a few hundred requests a month) |
| Reading the app keys (#8, #27) | SSM Parameter Store standard parameters, an IAM user | $0 |
| App subdomains (#33) | Route 53 A records `<app>.daysofme.com` in the zone the domain registration created. The domain and the zone are billed yearly (project-standards `docs/costs.md`) | about $0.50 for the zone, queries under $0.01 |
| Study notes wiki (develop-skill#30) | S3 `sirloinbh-wiki-site-<account ID>` (about 25 MB) behind CloudFront at `wiki.daysofme.com`, with a public certificate | under $0.1: CloudFront's free allowance (1 TB and 10 million requests a month) covers one reader, the certificate is free, S3 storage and about 5,000 uploads per deploy cost a few cents |
| Audit trail (#102) | CloudTrail trail `sirloinbh-audit`, management events only, in S3 `sirloinbh-cloudtrail-logs-<account ID>`, logs kept 365 days (section 14) | $0 for the first management-event trail; S3 storage under $0.1 a month for one person's account ($0.025/GB-month, a few MB of logs a month) |
| Logs | Docker json-file, 10MB x 3 rotation per container | $0 |
| AWS Budgets | `monthly_budget_usd`, default $20. Email at 50% and 80% of actual spend and 100% of forecasted spend | Free (a budget used only for alerts) |
| Cost anomaly detection (#100) | A `SERVICE` monitor and a daily email subscription to `budget_emails`, sent when one service's unexpected spend reaches `cost_anomaly_threshold_usd` (default $5) | Free |
| Total | | **about $14-15** (plus 10% VAT, about $15-17) |

- The budget alert does not stop spending. It covers the cost of the whole personal account. Keep `monthly_budget_usd` above the monthly total with VAT, or the forecast alert fires every month; check that `terraform.tfvars` does not override it with a lower value.
- Cost anomaly alert (#100, `cost.tf`): the budget fires late and only on the total, so AWS Cost Anomaly Detection also watches each service and sends a daily email when the unexpected spend is at least `cost_anomaly_threshold_usd`. A leaked key that creates resources shows up first as one service jumping. Before the first apply, run `aws ce get-anomaly-monitors --profile <personal profile>`: an account allows only one dimensional `SERVICE` monitor, so if AWS already made one, import it (`terraform import aws_ce_anomaly_monitor.services <monitor ARN>`) instead of creating a second. After apply, `aws ce get-anomaly-subscriptions` should list the subscription with your email. The `terraform-uptime-alerts` policy gives Terraform the `ce` actions, inside the boundary of #98.
- Cost sources: [Lightsail pricing](https://aws.amazon.com/lightsail/pricing/), [Budgets pricing](https://aws.amazon.com/aws-cost-management/aws-budgets/pricing/). The actual bill follows the prices and taxes at billing time.
- ECR and CloudWatch Logs are not used. S3 holds the DB dump copies and study-log's files. The user decided to keep an off-server copy instead of leaving a long-lived AWS key on the server (2026-10-27, project-standards#262), and to add a key for study-log's files because the server cannot use an IAM role (2026-11-17, #53). The server has five keys: one that can only upload to the backup bucket, one that can read only the app keys in SSM, one that can only write the certificate challenge record, one that can only read, write and delete study-log's files (section 10), and one that can only send the two uptime metrics and publish to the uptime topic (#105, section 8).
- Each app is `https://<app>.daysofme.com`, only from allowed IPs. The shared reverse proxy on the server (project-standards#253) takes 80 and 443 and forwards each name to the app's web port on `127.0.0.1`, which is not open in the firewall.

## 1. One-time setup

### 1-1. Tools

Install the Terraform CLI and the AWS CLI. The Terraform version follows `versions.json` (`terraform.cli`) in `sirloinbh/project-standards`.

```powershell
winget install --id Hashicorp.Terraform --version <terraform.cli in versions.json> --exact
winget install --id Amazon.AWSCLI --exact
```

### 1-2. AWS credentials and the Terraform user's permissions (do not create a root key)

Create an IAM user only for Terraform and use that user's access key. Since #79 Terraform manages that user's own `terraform-*` policies, inside a permissions boundary that only the account administrator can change. Steps 1-3, 5, and 6 are done by hand, once.

1. Sign in to the console as the root account, then go to IAM → Users → Create user. Name: `terraform-workout` (`iam.tf` and `scripts/bootstrap-iam.sh` use this name). Do not give console access.
2. Permissions tab → Add permissions → Create inline policy → JSON (if you already created the user, replace the existing inline policy with this content. `BackupBucket` and `ServerUsers` were added in #7 and #8). This inline policy stays outside Terraform: the user cannot edit its own inline policies.
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
3. Bootstrap (#79, #85, #88): open AWS CloudShell in the console as the root account or an administrator (any region) and paste:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/sirloinbh/shared-aws-infrastructure/main/scripts/bootstrap-iam.sh | bash
   ```
   It prints one `OK ...` line per step and ends with `OK bootstrap finished`; a `FAIL ...` line stops it. Running it again changes only what differs, so it is also how a boundary change reaches AWS. It does five things:
   - Creates the policy `terraform-role-boundary` (#85): the most any role that Terraform creates can do, namely list, read, upload, and delete files in the `sirloinbh-wiki-site-*` buckets and clear a CloudFront cache (`cloudfront:CreateInvalidation`). It is what the wiki deploy role needs, nothing more.
   - Creates the policy `terraform-server-user-boundary` (#88): the most any server user `sirloinbh-apps-*` can do, namely exactly what the four inline policies of section 10 allow together: upload to the backup bucket, write the `_acme-challenge.<root_domain>` TXT record (and list zones and wait for the change), read SSM parameters under `/sirloinbh/` in `ap-northeast-2`, and get, put, delete, and list the study-log files, and (#105) put CloudWatch metrics in the `ProjectStandards/Uptime` namespace and publish to the `sirloinbh-uptime-alerts` topic. It looks up the hosted zone of `daysofme.com`, so it stops if the zone is missing.
   - Creates the policy `terraform-boundary` and sets it as the user's permissions boundary. Whatever other policies say, the user can do no more than this: Lightsail, Route 53, Budgets, CloudFront, ACM, S3 buckets named `sirloinbh-*`, SSM parameters under `/sirloinbh/`, and, since #98, SNS topics, CloudWatch alarms and CloudTrail trails named `sirloinbh-*` or `workout-memo-*`, Cost Explorer anomaly monitors and subscriptions (read access to Cost Explorer), and the account-level S3 public access block, and IAM only on the server users `sirloinbh-apps-*`, the wiki deploy role `sirloinbh-wiki-*` and the GitHub OIDC provider, the `terraform-*` policies, and itself. It cannot assume roles, and it cannot attach any policy whose name does not start with `terraform-`. It can create a `sirloinbh-wiki-*` role, write a role's inline policy, or set a role's boundary only when that boundary is `terraform-role-boundary`, and it can never remove a role's boundary (#85). So a role with a wide inline policy, or one that trusts another repository, still can do no more than the role boundary allows. The same holds for the server users (#88): it can create a `sirloinbh-apps-*` user, write its inline policy, or set its boundary only when that boundary is `terraform-server-user-boundary`, it cannot attach a managed policy to one, and it can never remove a user's boundary. The `iam:CreateUser` and `iam:PutUserPolicy` of step 2 are therefore capped by this rule.
   - Creates the policy `terraform-iam-self` and attaches it to the user: create, version, and delete policies named `terraform-*`, attach and detach them only on `user/terraform-workout`, read its own user, and set `terraform-server-user-boundary` on a `sirloinbh-apps-*` user (the inline policy of step 2 does not allow `iam:PutUserPermissionsBoundary`, and the user cannot edit it).
   - The policies deny removing or changing the user's boundary, removing any user's boundary, and editing `terraform-boundary`, `terraform-iam-self`, `terraform-role-boundary`, or `terraform-server-user-boundary`. The last lines check this, the role and server user rules above, and what a server user can do under its boundary, with the IAM policy simulator.
   - The boundary is a managed policy, which AWS limits to 6,144 characters without whitespace; it uses about 5,850 after #109 (the cost anomaly create actions need `"Resource": "*"`, because they support no resource type). Before adding more statements, check the size (`aws iam get-policy-version` on `terraform-boundary`, or render the heredoc and count) and prefer wildcards over new statements.
4. The other managed policies are Terraform resources in `iam.tf`; each document is `iam-policies/<name>.json`. They are managed policies, not inline ones, because all inline policies of one user share a 2,048-character limit, which the policy in step 2 nearly fills.

   | Policy | Since | What it lets Terraform do |
   |---|---|---|
   | `terraform-route53-dns` | #33, #69 | Read the hosted zone and change its records, and manage the parameter that holds the static IP and let the PC read it (project-standards `server-ip` and `server-ssh`) |
   | `terraform-state` | #63, #53 | Create the state bucket, and read and write the state and its lock file; manage the study-log files bucket |
   | `terraform-wiki-site` | develop-skill#30 | The wiki bucket, CloudFront, its certificate, the GitHub OIDC provider, and the wiki deploy role |
   | `terraform-uptime-alerts` | #105, #100 | The `sirloinbh-uptime-alerts` topic and its email subscriptions, the `sirloinbh-uptime-*` alarms, and the Cost Explorer anomaly monitors and subscriptions. Created by Terraform, not imported |
   | `terraform-guardrails` | #101, #102 | The account-level S3 public access block, and the `sirloinbh-audit` CloudTrail trail with its log bucket. Created by Terraform, not imported |

   - **The per-user limit** (#116): an IAM user can have at most 10 managed policies (20 after a quota increase). The user has `terraform-iam-self` (made by the bootstrap) and the five policies above, six in all. The names are historical: a policy holds the statements of its area, not only what its name says. Put new statements into the fitting document if it stays under 6,144 characters without whitespace; add a new policy only for a new area.
   - **Merging policies** (#116, the apply order): the change updates four policies in place and deletes four (`terraform-server-ip`, `terraform-app-files`, `terraform-cost-anomaly`, `terraform-cloudtrail`) with their attachments. Terraform may delete in parallel with the updates, so apply in two steps and nothing loses a permission: (1) `terraform plan -out=<file> "-target=aws_iam_policy.terraform[\"terraform-route53-dns\"]" "-target=aws_iam_policy.terraform[\"terraform-state\"]" "-target=aws_iam_policy.terraform[\"terraform-uptime-alerts\"]" "-target=aws_iam_policy.terraform[\"terraform-guardrails\"]"` shows four in-place updates only (new versions that add statements); apply that file. (2) Then a normal plan and apply shows the four deletions (attachment and policy each) and `0 to add`; the merged policies already hold the permissions. Neither step attaches anything, so the 10-policy limit cannot block it. A policy that never reached AWS (for example `terraform-cost-anomaly` if its attach failed) is simply missing from the plan. If a run stops half way, plan again; the state tells what is left.
   - **Changing or adding a policy** is a normal PR: edit the JSON file, or add `iam-policies/terraform-<name>.json` and its name to `local.terraform_policies`. Then plan and apply as in section 2 with the `workout-personal` profile. The name must start with `terraform-`.
   - **A change that needs a service or resource outside the boundary** still fails with AccessDenied after apply. Change the boundary in `scripts/bootstrap-iam.sh` in a PR, and after the merge the user runs step 3 again.
   - **Adopting the existing policies**: before #79 these were made by hand in the console (five then; #116 merged two of them away, three remain). The `import` blocks in `iam.tf` adopt them, so the first plan after the bootstrap shows `6 to import` and no changes for them. If it shows a change to them, do not apply: the JSON file differs from the policy in AWS.
   - **A brand-new account**, where the three imported policies do not exist yet: delete the two `import` blocks in `iam.tf`. With the local backend of 3-2, run `terraform apply "-target=aws_iam_user_policy_attachment.terraform"` first so the user gets its policies (including `terraform-state`), then continue with 3-2 and section 2.
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
- `wiki_auth_sha256`: the password hash of the study notes wiki (section 12)

Copy `state.tfbackend.example` to `state.tfbackend` (also excluded from git) and fill in `bucket` (the `state_bucket` output, `sirloinbh-terraform-state-<account ID>`) and `profile` (the same as `aws_profile`). `terraform init` reads it to find the remote state (section 3).

When you create the files in PowerShell 5.1, write them as UTF-8 without BOM: `[IO.File]::WriteAllText(<path>, <content>, (New-Object Text.UTF8Encoding $false))`.

## 2. Apply the infrastructure

```powershell
terraform init "-backend-config=state.tfbackend"
terraform plan "-out=deploy.tfplan"   # the list of creates and changes, and the account check (without quotes, PowerShell splits `-out=` at the dot)
terraform apply deploy.tfplan
terraform output                      # static_ip, ssh, app_urls, server_ip_parameter, backup_bucket, the server IAM user names
```

- What gets created: the SSH key registration, the instance, the static IP and its attachment, the firewall (ports 22, 80, and 443 open only to the allowed IPs), the monthly budget alert, the S3 buckets for DB dump copies and study-log files, the S3 bucket for the Terraform state (#63), the app subdomain records, five IAM users for the server (section 10), the uptime alert topic and two alarms (section 8), and the Terraform user's own `terraform-*` policies (section 1-2, #79).
- In a new account the state bucket does not exist yet, so `terraform init` with the backend fails. Create the bucket first as in 3-2.
- If the plan has a replacement (`-/+`) or a deletion, do not apply. Recreating the static IP changes the public address.
- `user-data.sh` runs on the first boot. Lightsail runs user_data with `/bin/sh`, so an sh wrapper writes and runs a bash script (`/usr/local/sbin/server-init`). It sets up only the host baseline: the time zone, 2GB of swap, Docker and Compose, and the Docker log limits. It takes a few minutes. Apps, the proxy, certificates, the shared `.env`, and timers are not set up; a lost server comes back from a snapshot (section 13).
- `user_data` runs only on the first boot. Changing it does not recreate the existing instance (`ignore_changes`).

## 3. State management

- The state lives in the S3 bucket `sirloinbh-terraform-state-<account ID>` (`state_bucket` output) under the key `shared-aws-infrastructure/terraform.tfstate` (#63). `versions.tf` has the `backend "s3"` block; the bucket name and the profile come from the git-ignored `state.tfbackend` (1-4).
- Every plan and apply takes a lock: a `terraform.tfstate.tflock` object next to the state (`use_lockfile`, Terraform 1.10 or later). A second run at the same time stops with "Error acquiring the state lock". Wait for the other run. Only if a run was killed and no other run is going, remove the lock with `terraform force-unlock <lock ID from the error>`.
- Nothing has to be copied after an apply. Back up only `terraform.tfvars` and `state.tfbackend` outside the repo when you change them (they hold personal values, not the state). Avoid folders that sync to the cloud, such as OneDrive.
- On another PC: clone the repo, put `terraform.tfvars` and `state.tfbackend` in this folder, then `terraform init "-backend-config=state.tfbackend"` and `terraform plan` must show "No changes".
- Raising the provider version saves the state in a new format that cannot be undone. Merge the version-change PR first, then apply.

### 3-1. First move from the local state (once)

The bucket was created while the state was still local (#74). Do this once on the PC that has `terraform.tfstate`.

1. Check the tools and rights: `terraform version` is 1.10 or later, and the Terraform user has the `terraform-state` policy (1-2 step 4).
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
aws lightsail get-instance-port-states @p --instance-name sirloinbh-apps --output table
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
| `module.backups` (the bucket and its 6 settings in `modules/private_bucket`: public access block, ownership, encryption, `versioning[0]`, lifecycle, policy) | Possible (bucket name) | import. Do not create it anew, because deleting the bucket also deletes the copies |
| `module.study_log_files` (the bucket and its 6 settings: public access block, ownership, encryption, `versioning[0]`, lifecycle, policy) | Possible (bucket name) | import. Do not create it anew, because deleting the bucket also deletes the files |
| `module.terraform_state` (the bucket and its 6 settings: public access block, ownership, encryption, `versioning[0]`, lifecycle, policy) | Possible (bucket name) | import. Do not create it anew; it has `prevent_destroy` and holds every earlier state |
| `aws_iam_user.*`, `aws_iam_user_policy.*` | Possible (user name, `user:policy name`) | import |
| `module.wiki` (the bucket and its 5 settings; no versioning) | Possible (bucket name) | import, or delete the bucket and let apply create it; the next deploy uploads the site again |
| `aws_cloudfront_distribution.wiki`, `aws_cloudfront_origin_access_control.wiki`, `aws_cloudfront_function.wiki` | Possible (distribution ID, access control ID, function name) | import. A new distribution would get another address, so the DNS records would change |
| `aws_acm_certificate.wiki`, `aws_route53_record.wiki*` | Possible (certificate ARN in us-east-1; `zone ID_name_type`) | import. `aws_acm_certificate_validation.wiki` cannot be imported; apply creates it without changing AWS |
| `aws_iam_openid_connect_provider.github`, `aws_iam_role.wiki_deploy`, `aws_iam_role_policy.wiki_deploy` | Possible (provider ARN, role name, `role:policy name`) | import |
| `aws_iam_policy.terraform[*]`, `aws_iam_user_policy_attachment.terraform[*]` (#79) | Possible (policy ARN, `user/policy ARN`) | The `import` blocks in `iam.tf` adopt them on the next plan. `terraform-boundary`, `terraform-iam-self`, `terraform-role-boundary`, and `terraform-server-user-boundary` are not in the state; they stay as the bootstrap (section 1-2, step 3) made them |

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
   aws lightsail get-instance-port-states --profile workout-personal --instance-name sirloinbh-apps --query "portStates[].{port:fromPort,aliases:join(',',cidrListAliases)}" --output table   # aliases must be empty
   ```
4. On the first connection, compare the server fingerprint it shows with the AWS value, then answer `yes`.
   ```powershell
   aws lightsail get-instance-access-details --profile workout-personal --instance-name sirloinbh-apps --protocol ssh --query "accessDetails.hostKeys[].{alg:algorithm,sha256:fingerprintSHA256}" --output table
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

### 7-1. CAA record (#103)

`aws_route53_record.caa` (`dns.tf`) puts a CAA record at the zone apex: `0 issue "letsencrypt.org"` and `0 issue "amazon.com"`. Only these two authorities may issue certificates for the domain and its subdomains. Let's Encrypt is the server's certbot (wildcard certificate), and Amazon is the ACM certificate of the wiki (section 12). With no `issuewild` entry, the `issue` entries also cover the wildcard certificate.

- **Plan**: adds only this record (`1 to add`). No `-/+`.
- **Check after apply**: `nslookup -type=CAA <root_domain>` shows both entries. Then confirm the next certbot renewal (`cert.sh` dry run, project-standards `docs/server-proxy.md`) and ACM renewal still work.
- **Another authority later**: add one more `0 issue "<ca-domain>"` string to `records` in `dns.tf` and apply, before requesting a certificate from it. If a renewal fails with a CAA error, this record is the first thing to check.

## 8. Alarms (optional)

The Terraform AWS provider has no resource for Lightsail metric alarms. Create them with the CLI if you need them. Each alarm costs about $0.10 a month, and an email contact works only after you approve the AWS confirmation email.

```powershell
aws lightsail create-contact-method --profile workout-personal --protocol Email --contact-endpoint <email>
aws lightsail put-alarm --profile workout-personal --alarm-name workout-memo-status --monitored-resource-name sirloinbh-apps --metric-name StatusCheckFailed --comparison-operator GreaterThanOrEqualToThreshold --threshold 1 --evaluation-periods 2 --notification-enabled --contact-protocols Email
```

### 8-1. Uptime alerts (#105)

The server judges its own signals and sends two numbers to CloudWatch (project-standards `docs/server-proxy.md`, "AWS alert path"; `signals.sh evaluate` runs at the end of every 5-minute `public-check.sh` run). `uptime.tf` creates the receiving side, all in `var.region`:

| Resource | What it does |
|---|---|
| SNS topic `sirloinbh-uptime-alerts` | Receives the alarms and the server's own messages. The server's message names the failing signals (an alarm mail carries only the alarm name) |
| Email subscription | One per address in `uptime_alert_emails`, or in `budget_emails` when that is empty. Each recipient must confirm the AWS email; until then the subscription stays pending and no mail arrives |
| Alarm `sirloinbh-uptime-heartbeat` | `HeartbeatOk` (always 1 per run), sum over 5 minutes, below 1 for 3 periods in a row. Missing data counts as breaching, so a dead server, a stopped timer, a broken network, or a revoked key raises it after about 15 minutes. It sends a mail when it fires and when it recovers |
| Alarm `sirloinbh-uptime-failing-signals` | `FailingSignals` (how many signals fail or are stale) above 0 for one 5-minute period. Missing data keeps the current state, so a dead server does not send a false OK mail |
| IAM user `sirloinbh-apps-uptime-alerts` | `cloudwatch:PutMetricData` with the condition `cloudwatch:namespace` = `ProjectStandards/Uptime` and `sns:Publish` on this topic, nothing else. It is separate from the upload-only backup key; key rotation follows #104 |
| Policy `terraform-uptime-alerts` | What the Terraform user needs for the topic, subscriptions and alarms (section 1-2, step 4) |

- **Cost**: inside the free tier. 2 custom metrics (the free tier has 10), 2 alarms (10 free), about 17,000 API requests a month (1 million free), and email through SNS (1,000 free a month). The metrics and alarms cost nothing; check the first bill.
- **Names**: the namespace, the topic name, and the alarm names are written in `uptime.tf`, `iam-policies/terraform-uptime-alerts.json`, and `scripts/bootstrap-iam.sh` (`UPTIME_NAMESPACE`, `UPTIME_TOPIC`). Change all places together; the server's `AWS_ALERT_NAMESPACE` must equal the namespace.
- **Order**: merge the PR, run the bootstrap again (section 1-2, step 3: the server user boundary gets `cloudwatch:PutMetricData` and `sns:Publish`, and `terraform-boundary` gets the alert services of #98), then plan and apply. Before the bootstrap, the apply fails with AccessDenied.
- **The plan** adds exactly: the policy `terraform-uptime-alerts` and its attachment, the topic, one subscription per recipient, the user and its inline policy, and two alarms, with no `-/+` and no change to existing resources. The existing five policies stay imports.
- **After apply** [user]: confirm the SNS email, create the access key of `sirloinbh-apps-uptime-alerts` (section 10, steps 1-2), put the five `AWS_ALERT_*` keys in `/opt/project-standards/.env`, and set `NOTIFY_SINK=both`. To test it, stop `public-check.timer` for 15 minutes (the heartbeat alarm mails) and start it again (the OK mail).
- **Silence an alarm**: in the console, CloudWatch → Alarms → the alarm → Actions → Disable alarm actions (mail stops, state keeps updating), and enable it again afterwards. To silence everything for a long time, set `NOTIFY_SINK=healthchecks` on the server. Do not delete the subscription for a short silence: the recipient would have to confirm again.

## 9. Teardown

Running `terraform destroy` deletes the instance, static IP, firewall, and budget, and the DB and dumps inside the server go with them. Bring the backups you need to your PC first (the app repo doc). Automatic snapshots can remain after the instance is deleted and may keep costing money, so check them in the Lightsail console.

Every S3 bucket comes from `modules/private_bucket`, which has `prevent_destroy` (#63, #80), so `terraform destroy` stops with an error while the buckets are in the configuration. For a full teardown, first remove that line from `modules/private_bucket/main.tf` in a local, uncommitted copy, and empty the buckets you no longer need. Also move the state back to a local file first (remove the `backend` block in the same copy, then `terraform init -migrate-state`), or the destroy deletes the bucket that holds the state it is writing to.

## 10. Creating the server keys (#7, #8)

You cannot attach an IAM role to the server, so the server needs access keys to use AWS. Terraform does not create the keys (so that no secret key stays in the state). Create them in the console after apply.

All apps on the server share these users, so they are named `sirloinbh-apps-*`, not after a specific app (project-standards ADR-0010). On 2026-10-29 they were first created as `workout-memo-*` and renamed the same day (`iam:UpdateUser`, plan `2 to add, 2 to change, 2 to destroy`: the users are renamed in place and the inline policies are attached again). While renaming, the `Resource` of `ServerUsers` in 1-2 must contain both the old and the new names.

| IAM user (`terraform output`) | What it can do | Keys in the server's shared file `/opt/project-standards/.env` |
|---|---|---|
| `sirloinbh-apps-backup-uploader` | Only upload files to the backup bucket (no read, list, or delete) | `BACKUP_S3_BUCKET` (= the `backup_bucket` output value), `BACKUP_AWS_ACCESS_KEY_ID`, `BACKUP_AWS_SECRET_ACCESS_KEY` |
| `sirloinbh-apps-certbot` | Only write the `_acme-challenge.<root_domain>` TXT record in the domain's hosted zone (#33, project-standards ADR-0012). It cannot change any other record | `CERTBOT_AWS_ACCESS_KEY_ID`, `CERTBOT_AWS_SECRET_ACCESS_KEY` (read by `cert.sh` of the server reverse proxy, project-standards `docs/server-proxy.md`) |
| `sirloinbh-apps-study-log-files` (#53) | Only get, put and delete objects in the study-log files bucket, and list its keys so a missing file reads as not found. It cannot change the bucket or remove earlier versions | Not in the shared file: only study-log uses it. Put `FILE_BUCKET` (= the `study_log_files_bucket` output value), `AWS_REGION=ap-northeast-2`, `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` in study-log's server `.env` (`/opt/study-log/.env`), which its compose file passes to the API |
| `sirloinbh-apps-study-log-mail` (#120) | Only `ses:SendEmail`, from the one verified address `study_log_mail_address` (`ses:FromAddress` is pinned to it). It cannot send raw email, change identities or send from another address | Not in the shared file: only study-log uses it. Put `SES_AWS_ACCESS_KEY_ID` and `SES_AWS_SECRET_ACCESS_KEY` (this user's key), `SES_REGION` (= the `study_log_mail_region` output value), `REMINDER_EMAIL_FROM` (= the `study_log_mail_identity` output value) and `REMINDER_EMAIL_TO` (the same address, see below) in `/opt/study-log/.env`. `AWS_ACCESS_KEY_ID` there stays the files user's key |
| `sirloinbh-apps-uptime-alerts` (#105) | Only put CloudWatch metrics in the `ProjectStandards/Uptime` namespace and publish to the `sirloinbh-uptime-alerts` topic. It cannot read metrics, change alarms or subscribe | `AWS_ALERT_ACCESS_KEY_ID`, `AWS_ALERT_SECRET_ACCESS_KEY`, plus `AWS_ALERT_TOPIC_ARN` (= the `uptime_alert_topic_arn` output), `AWS_ALERT_REGION` and `AWS_ALERT_NAMESPACE` (read by `signals.sh` of the server proxy, project-standards `docs/server-proxy.md`, "AWS alert path") |
| `sirloinbh-apps-secrets-reader` | Only read (`ssm:GetParameter`) SSM parameters under `/sirloinbh/shared/` and `/sirloinbh/<app>/` for the apps in `local.registry.secretApps` (the generated `apps.json`, read in `registry.tf`; project-standards ADR-0014) | `SECRETS_AWS_ACCESS_KEY_ID`, `SECRETS_AWS_SECRET_ACCESS_KEY` (read by every app whose `.env.example` tags a key with `@ssm=`, and by apps that use the Claude API) |

1. Console → IAM → Users → the user above → Security credentials → Create access key → use case "Application running outside AWS". Write "lightsail-server" in the description tag.
2. Connect to the server and put the keys above in one place, the shared file `/opt/project-standards/.env`. Do not put them in each app. Type the values only on the server and do not leave them in chat or docs. Create the file once:
   ```bash
   sudo install -d -o ubuntu -g ubuntu -m 700 /opt/project-standards
   install -m 600 /dev/null /opt/project-standards/.env
   ```
   For an app's deploy script to read this file, the sync PR from project-standards#266 must be merged into that app.
3. Backup: run `sudo bash /opt/<app>/deploy/install-backup.sh`, then `bash /opt/<app>/deploy/backup.sh dump`, and check that "uploaded ... to s3://..." appears.
4. App keys: create the SSM parameter from your PC with `node tools/app-secrets.mjs set <parameter>` (project-standards; without a parameter it stores the Claude key at `/sirloinbh/shared/anthropic-api-key`), then check on the server that `bash /opt/<app>/deploy/ssm-get.sh <parameter> > /dev/null && echo ok` prints `ok` (the value is not printed).
5. To change a key, follow section 10-2. If a server key leaks, delete this user's keys and replace every app key in SSM too.

### 10-0. Email for study-log (#120)

study-log sends one review reminder a day through AWS SES (sirloinbh/study-log#365). Terraform (`mail.tf`) creates the SES email identity for `study_log_mail_address` (set in the git-ignored `terraform.tfvars`) and the user `sirloinbh-apps-study-log-mail`.

1. **Bootstrap first**: merge the PR, then run the bootstrap again (section 1-2, step 3) so both boundaries allow SES, then plan and apply. Before that the apply fails with AccessDenied. The new policy `terraform-app-mail` is one more managed policy on the Terraform user; IAM allows 10 per user by default, so the quota must already be raised (#116), or the attachment fails with `LimitExceeded`.
2. **Verify the identity**: after apply, SES mails a verification link to the address. Open it once; the identity stays `Pending` until then (`aws sesv2 get-email-identity --email-identity <address> --region ap-northeast-2 --query VerifiedForSendingStatus`, with the personal profile, prints `true` when done).
3. **Sandbox**: a new SES account can send only to verified addresses and at most 200 a day. The reminder goes to the same verified address it is sent from, so the sandbox is enough. Asking AWS for production access is not needed for one mail a day.
4. **Key and server**: make the access key as in step 1 above, put the five values from the table in `/opt/study-log/.env` and recreate the API container with study-log's deploy. Type the values only on the server.
5. **Check**: the study-log API logs `reminder_sent` the first morning after 08:00 Asia/Seoul with a review due, and the mail arrives (check the spam folder once).
6. **Stop**: empty `REMINDER_EMAIL_TO` or `REMINDER_EMAIL_FROM` in study-log's `.env` and recreate the container; the job stays off.

### 10-1. Server user boundary (#88)

All server users (six since #120) carry the permissions boundary `terraform-server-user-boundary` (`permissions_boundary` on each `aws_iam_user`), which the bootstrap makes (section 1-2, step 3). The server keys are long-lived, so whatever inline policy Terraform writes, a key can do no more than the table above. The Terraform user cannot create a `sirloinbh-apps-*` user or write its inline policy without that boundary, and cannot remove it.

- **Order**: merge the PR, run the bootstrap again (section 1-2, step 3) so `terraform-server-user-boundary` exists and `terraform-boundary` and `terraform-iam-self` have the new rules, then plan and apply. Before the bootstrap, the apply fails with AccessDenied.
- **The plan** shows, for this change, four in-place updates and nothing else: `aws_iam_user.backup_uploader`, `.certbot`, `.secrets_reader`, and `.study_log_files` (adds `permissions_boundary`), `0 to add, 4 to change, 0 to destroy`. The access keys and inline policies stay as they are. If an update still fails with AccessDenied because IAM has not spread the new policy versions yet, wait a minute and apply again.
- **After apply**, check that the server jobs still work: steps 3 and 4 above, a study-log file upload, and a certificate renewal dry run with the reverse proxy's `cert.sh` (project-standards `docs/server-proxy.md`).
- **Email (#120)**: `terraform-server-user-boundary` allows `ses:SendEmail` on identities in `ap-northeast-2` (the script cannot know the address), and the inline policy in `mail.tf` narrows it to the one identity and its `From` address. `terraform-boundary` lets the Terraform user manage SES identities (not send).
- **A new permission for a server user** needs it in both places: the inline policy in the `.tf` file and `terraform-server-user-boundary` in `scripts/bootstrap-iam.sh` (then the bootstrap again). The boundary pins the region `ap-northeast-2` and the domain `daysofme.com`; change `REGION` and `ROOT_DOMAIN` in the script if `var.region` or `var.root_domain` changes.

### 10-2. Rotate the server keys (#104)

The keys are long-lived and Terraform does not track them, so their age is checked by hand.

- **Interval**: replace every key at least every 90 days, and at once when one may have leaked. Check the ages every 90 days (put it in your calendar).
- **Age**: this lists each key's status and creation time for the six server users, with the personal profile. The Terraform user may call `iam:ListAccessKeys` on `sirloinbh-apps-*`:
  ```bash
  for u in backup-uploader certbot study-log-files study-log-mail uptime-alerts secrets-reader; do
    echo "== sirloinbh-apps-$u"
    aws iam list-access-keys --user-name "sirloinbh-apps-$u" --profile workout-personal       --query 'AccessKeyMetadata[].{Key:AccessKeyId,Status:Status,Created:CreateDate}' --output table
  done
  ```
  A key past 90 days (compare `Created` with today) must be rotated. To see when a key was last used, run `aws iam get-access-key-last-used --access-key-id <key ID>`. That action is not in the Terraform user's boundary (it is read only; allowing it means a change to `scripts/bootstrap-iam.sh`), so run it with an admin identity or read "Last used" in the console (IAM → Users → the user → Security credentials). A key that was never used or not used for a long time can be deleted without a replacement, after you check which app reads it.
- **Steps** (one user at a time; a user holds at most two keys):
  1. Make the second key as in step 1 above, with the description "lightsail-server".
  2. On the server, put the new values in `/opt/project-standards/.env` (or `/opt/study-log/.env` for `study-log-files` and `study-log-mail`), or in SSM for the apps' own keys. Type them only on the server.
  3. Check the apps with the commands of the table's matching step: backup (step 3), SSM read (step 4), a study-log file upload, a certificate renewal dry run with `cert.sh`, or an uptime alert test.
  4. Deactivate the old key (console → Make inactive) and wait a day for failures.
  5. Delete the old key. If something fails after step 4, make the old key active again, fix the cause, and repeat.

## 11. Resize the server (from a snapshot)

Lightsail cannot change a running instance's plan. Changing `bundle_id` alone makes Terraform replace the instance with a new one that has only the `user-data.sh` host baseline (no apps), and the DB on it is lost. Resize by building a new instance from a snapshot, then point Terraform at it. Done on 2026-11-15 from 1 GB (`micro_3_0`) to 2 GB (`small_3_0`) (#38, project-standards#564).

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

## 12. Study notes wiki (develop-skill#30)

`wiki.tf` hosts the static wiki that `sirloinbh/develop-skill` builds from its notes: a private S3 bucket, a CloudFront distribution at `https://wiki.daysofme.com/`, and a CloudFront function that asks for one user name and password. The decision and its reasons are in develop-skill `docs/wiki-site.md`. The notes repository uploads the site itself; this repo only owns the AWS resources.

### 12-1. First apply

1. The Terraform user needs the `terraform-wiki-site` policy (section 1-2, step 4). Since #79 `iam.tf` manages it.
2. Choose a user name and a password, and compute the hash that the function compares. Run this in PowerShell on your PC; it asks for the password without showing it and prints only the hash.
   ```powershell
   $user = "<user name>"
   $pass = Read-Host "Wiki password" -AsSecureString
   $plain = [Net.NetworkCredential]::new("", $pass).Password
   $header = "Basic " + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${user}:$plain"))
   -join ([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($header)) | ForEach-Object { $_.ToString("x2") })
   ```
   Put the printed value in `terraform.tfvars` as `wiki_auth_sha256 = "<64 characters>"`. Do not write the password anywhere; keep it in your password manager.
3. Plan and apply as in section 2. The first plan adds 17 resources and changes or destroys none (more if earlier changes such as the server IP parameter of #69 or the state bucket of #63 are not applied yet). The certificate validation and the distribution take 5 to 15 minutes.
   - If the plan fails because the OIDC provider `token.actions.githubusercontent.com` already exists in the account, import it instead: `terraform import aws_iam_openid_connect_provider.github arn:aws:iam::<account ID>:oidc-provider/token.actions.githubusercontent.com`.
4. Give the outputs to the notes repository as repository variables (they are not secrets; the role can be assumed only by that repository's `main` branch workflow). In the develop-skill folder, with the personal GitHub account:
   ```powershell
   gh variable set WIKI_DEPLOY_ROLE_ARN --repo sirloinbh/develop-skill --body (terraform -chdir=<this folder> output -raw wiki_deploy_role_arn)
   gh variable set WIKI_BUCKET --repo sirloinbh/develop-skill --body (terraform -chdir=<this folder> output -raw wiki_bucket)
   gh variable set WIKI_DISTRIBUTION_ID --repo sirloinbh/develop-skill --body (terraform -chdir=<this folder> output -raw wiki_distribution_id)
   ```
5. Run the `wiki` workflow of develop-skill once (Actions → wiki → Run workflow), then open `https://wiki.daysofme.com/` on the phone and enter the user name and password. The browser remembers them.

### 12-2. Operations

- **Change the password**: compute a new hash (step 2), replace `wiki_auth_sha256`, plan, and apply. Only the function changes (`0 to add, 1 to change`), and the new password works within about a minute.
- **How it stays private**: the function runs before the cache on every request, so a cached page is never served without the password. The bucket blocks public access and lets only this distribution read it.
- **Limits**: basic authentication has no lockout, so use a long random password. The hash is in the function code and in the state; someone who can read them can test password guesses offline.
- **A page shows old content**: the deploy workflow clears the CloudFront cache at the end. To do it by hand: `aws cloudfront create-invalidation --profile workout-personal --distribution-id <wiki_distribution_id> --paths "/*"`.
- **Teardown**: the bucket has `prevent_destroy` like every bucket here (section 9), and `terraform destroy` also fails while the bucket has files. Empty it first: `aws s3 rm s3://<wiki_bucket> --recursive --profile workout-personal`.

### 12-3. Deploy role trust: the immutable OIDC subject (#82)

The first `wiki` run failed with "Not authorized to perform sts:AssumeRoleWithWebIdentity". develop-skill uses GitHub's immutable OIDC subject, so the token's `sub` claim names the owner and the repository by name **and ID**: `repo:sirloinbh@129952654/develop-skill@1442840255:ref:refs/heads/main`. The trust policy compared it with the name-only form `repo:sirloinbh/develop-skill:ref:refs/heads/main`, which never matched.

- The trust policy now requires `<wiki_oidc_subject_prefix>:ref:refs/heads/main` (and `aud = sts.amazonaws.com`). The default of `wiki_oidc_subject_prefix` is the prefix above; the IDs are public, not secrets.
- Why IDs: a repository that is renamed, or deleted and re-created with the same name, gets a new ID, so it cannot assume the role.
- Read the prefix of a repository with the personal GitHub account. Use `sub_claim_prefix` when `use_immutable_subject` is `true`:
  ```powershell
  gh api repos/sirloinbh/develop-skill/actions/oidc/customization/sub
  # {"use_default":true,"use_immutable_subject":true,"sub_claim_prefix":"repo:sirloinbh@129952654/develop-skill@1442840255"}
  ```
- If the notes move to another repository, set `wiki_oidc_subject_prefix` in `terraform.tfvars` to that repository's prefix. The variable accepts only the immutable form `repo:<owner>@<owner ID>/<repo>@<repo ID>`.
- Applying the change: `plan` must show only `aws_iam_role.wiki_deploy` updated in place (`0 to add, 1 to change, 0 to destroy`). After the apply, re-run the `wiki` workflow (12-1 step 5).

### 12-4. Deploy role boundary (#85)

The deploy role carries the permissions boundary `terraform-role-boundary` (`permissions_boundary` in `wiki.tf`), which the bootstrap makes (section 1-2, step 3). Whatever inline policy or trust policy Terraform writes, the role can only list, read, upload, and delete files in the `sirloinbh-wiki-site-*` buckets and clear a CloudFront cache. The Terraform user cannot create a `sirloinbh-wiki-*` role or write its policy without that boundary, and cannot remove it.

- **Order**: merge the PR, run the bootstrap again (section 1-2, step 3) so `terraform-role-boundary` exists and `terraform-boundary` has the new rules, then plan and apply. Before the bootstrap, the apply fails with AccessDenied.
- **The plan** shows, for this change, two in-place updates and nothing else: `aws_iam_policy.terraform["terraform-wiki-site"]` (adds `iam:PutRolePermissionsBoundary`) and `aws_iam_role.wiki_deploy` (adds `permissions_boundary`), `0 to add, 2 to change, 0 to destroy`. The role waits for the policy. If the role update still fails with AccessDenied because IAM has not spread the new policy version yet, wait a minute and apply again.
- **After the apply**, re-run the `wiki` workflow (12-1 step 5); it must upload and clear the cache as before.
- **A new permission for the deploy role** needs it in both places: the inline policy in `wiki.tf` and `terraform-role-boundary` in `scripts/bootstrap-iam.sh` (then the bootstrap again).

## 13. Recover the server from a snapshot (#64)

The Lightsail snapshot is the only recovery path for the whole server (user decision 2026-11-21). The server holds every app, shared-auth, shared-ai, the nginx proxy, the certbot certificates, the shared `.env`, and the timers, and no repo can rebuild them all; `user-data.sh` gives a new instance only the host baseline. Use this when the instance is broken or lost. To change the plan size instead, use section 11.

1. Back up the state as in section 3.
2. Pick the snapshot. The automatic ones are daily at 03:00 Seoul, and AWS keeps the latest 7:
   ```powershell
   aws lightsail get-auto-snapshots --profile workout-personal --resource-name <old> --query "autoSnapshots[].{date:date,status:status}" --output table
   ```
   A manual snapshot (`get-instance-snapshots`) also works. Take one before any risky server change: `aws lightsail create-instance-snapshot --instance-name <old> --instance-snapshot-name <old>-<date>`.
3. Build a new instance with a **new name** from it. From an automatic snapshot:
   ```powershell
   aws lightsail create-instances-from-snapshot --profile workout-personal --instance-names <new> --availability-zone ap-northeast-2a --source-instance-name <old> --restore-date <YYYY-MM-DD> --bundle-id <bundle> --key-pair-name workout-memo-deploy --ip-address-type ipv4 --add-ons 'addOnType=AutoSnapshot,autoSnapshotAddOnRequest={snapshotTimeOfDay=18:00}' --tags key=Project,value=workout-memo
   ```
   From a manual snapshot, use `--instance-snapshot-name <snapshot>` instead of `--source-instance-name` and `--restore-date`.
4. Do steps 4-7 of section 11: close the default firewall, move the static IP, check `https://<app>.<root_domain>/api/health` for every app in `apps.json`, stop the old instance if it still runs, and point Terraform at the new instance (`instance_name` in `terraform.tfvars`, `state rm`, `import`, a plan with 1 to add, 0 to change, 0 to destroy).
5. Data written after the snapshot is not on the new instance. If an app needs it, restore that app's latest off-server dump from S3 `sirloinbh-db-backups-<account ID>` with the app repo's backup restore steps.
6. Delete the old instance and manual snapshots you no longer need after about a week, as in section 11 step 8.

If no snapshot is left (for example, the instance and its snapshots were deleted), there is no scripted rebuild: build a server with `terraform apply`, then install each app with its own repo's deploy docs and restore the databases from the S3 dumps.

## 14. Audit trail (CloudTrail, #102)

The account only had the 90-day CloudTrail event history. If a server key leaks, older events are gone. The trail `sirloinbh-audit` (`cloudtrail.tf`) keeps management events (who created, changed or deleted what, and every other control-plane call) in the private S3 bucket `sirloinbh-cloudtrail-logs-<account ID>` (the `cloudtrail_log_bucket` output).

- **What it records**: management events for reads and writes, in all regions, plus global service events (IAM, STS, CloudFront). Log file validation is on, so a changed or deleted log file can be detected. Data events (S3 object reads, Lambda invokes) and Insights are not recorded because they are billed.
- **Cost**: the first trail that records management events in an account is free. Only S3 storage is paid, under $0.1 a month here. A second management-event trail would be billed, so do not add one. Logs expire after 365 days (`cloudtrail_retention_days`).
- **Bucket**: it comes from `modules/private_bucket` (no public access, SSE-S3, HTTPS only, no versioning). Its policy lets only the CloudTrail service write, only for this trail (`aws:SourceArn`), under `AWSLogs/<account ID>/`.
- **Before the plan**: confirm no trail exists, so this one is the free first trail: `aws cloudtrail describe-trails --profile workout-personal --region ap-northeast-2 --query "trailList[].{name:Name,multi:IsMultiRegionTrail}"`. If one exists, stop and decide before applying.
- **Order**: merge, run the bootstrap again if `terraform-boundary` has not been updated for #98 (section 1-2, step 3), then plan and apply. The plan should add only the bucket and its settings, the trail, and, in the `terraform-guardrails` policy, the trail rights, with no `-/+`.
- **Check after apply**: `aws cloudtrail get-trail-status --name sirloinbh-audit --profile workout-personal --region ap-northeast-2 --query IsLogging` prints `true`. The first log file appears in the bucket within about 15 minutes.
- **Read the logs**: console → CloudTrail → Event history covers the last 90 days. For older events, open the bucket (`AWSLogs/<account ID>/CloudTrail/<region>/<yyyy>/<mm>/<dd>/*.json.gz`) and download the files for the day, or list them with `aws s3 ls s3://<bucket>/AWSLogs/ --recursive`. Check integrity with `aws cloudtrail validate-logs --trail-arn <trail ARN> --start-time <UTC time>`.
- **Remove the trail**: delete `aws_cloudtrail.audit` first. The log bucket has `prevent_destroy`, as every bucket from the module does.

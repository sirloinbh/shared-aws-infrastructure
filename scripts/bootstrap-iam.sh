#!/usr/bin/env bash
# One-time bootstrap that lets Terraform manage its own IAM policies (#79) and caps the roles (#85)
# and server users (#88) it manages. Steps are in docs/operations.md 1-2.
# Run it in AWS CloudShell of the personal account, signed in as root or an administrator, not as
# terraform-workout. It is safe to run again: each step changes AWS only when it differs from below.
#
#   1. Policy `terraform-role-boundary`: the most a role that terraform-workout creates can ever do
#      (upload the wiki site and clear its cache). terraform-boundary lets the user create a role,
#      write its policy, or set its boundary only with this boundary, and never remove it (#85).
#   1b. Policy `terraform-server-user-boundary`: the most a server user (`sirloinbh-apps-*`) can ever
#      do (upload backups, write the certbot TXT record, read app keys, use the study-log files, send the
#      uptime metrics, publish to the uptime topic and send email through SES, #120). The
#      same rules as for roles hold for these users and their inline policies (#88).
#   2. Policy `terraform-boundary`: the most terraform-workout can ever do. It is set as the user's
#      permissions boundary, so every policy Terraform writes for itself is capped by it.
#   3. Policy `terraform-iam-self`: lets terraform-workout create, version and delete policies named
#      `terraform-*` and attach them only to itself, and set the server user boundary on a server user.
#   All four are guarded: the user cannot edit or delete them or remove its own boundary, so
#   Terraform cannot widen either cap.
set -euo pipefail
export AWS_PAGER=""

TF_USER="terraform-workout"
# The server users work in this region (var.region) and renew the certificate of this domain (var.root_domain).
REGION="ap-northeast-2"
ROOT_DOMAIN="daysofme.com"
# The uptime alert path (#105, uptime.tf): one metric namespace and one SNS topic name, the same as in uptime.tf.
UPTIME_NAMESPACE="ProjectStandards/Uptime"
UPTIME_TOPIC="sirloinbh-uptime-alerts"

say() { printf 'OK %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
normalize() { python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), sort_keys=True, separators=(",", ":")))'; }

# Creates the managed policy, or adds a new default version when the document changed.
upsert_policy() {
  local name="$1" doc="$2" arn="arn:aws:iam::${ACCOUNT}:policy/$1" err current oldest
  if ! err=$(aws iam get-policy --policy-arn "$arn" 2>&1 >/dev/null); then
    case "$err" in
      *NoSuchEntity*) ;;
      *) fail "reading policy $name: $err" ;;
    esac
    aws iam create-policy --policy-name "$name" --policy-document "$doc" \
      --description "Made by scripts/bootstrap-iam.sh in sirloinbh/shared-aws-infrastructure. Terraform must not edit it." >/dev/null
    say "policy $name created"
    return
  fi
  current=$(aws iam get-policy-version --policy-arn "$arn" \
    --version-id "$(aws iam get-policy --policy-arn "$arn" --query Policy.DefaultVersionId --output text)" \
    --query PolicyVersion.Document --output json | normalize)
  if [ "$current" = "$(printf '%s' "$doc" | normalize)" ]; then
    say "policy $name already up to date"
    return
  fi
  # A managed policy keeps at most 5 versions; drop the oldest non-default one first.
  if [ "$(aws iam list-policy-versions --policy-arn "$arn" --query 'length(Versions)' --output text)" -ge 5 ]; then
    oldest=$(aws iam list-policy-versions --policy-arn "$arn" \
      --query 'sort_by(Versions[?IsDefaultVersion==`false`], &CreateDate)[0].VersionId' --output text)
    aws iam delete-policy-version --policy-arn "$arn" --version-id "$oldest"
  fi
  aws iam create-policy-version --policy-arn "$arn" --policy-document "$doc" --set-as-default >/dev/null
  say "policy $name updated to the new version"
}

# Checks one simulated decision for terraform-workout: "allowed", or "denied" (explicit or implicit).
expect_decision() {
  local want="$1" action="$2" resource="$3" label="$4" got
  shift 4
  got=$(aws iam simulate-principal-policy --policy-source-arn "$USER_ARN" \
    --action-names "$action" --resource-arns "$resource" "$@" \
    --query 'EvaluationResults[0].EvalDecision' --output text)
  case "$want:$got" in
    allowed:allowed | denied:explicitDeny | denied:implicitDeny) say "check: $label ($got)" ;;
    *) fail "check '$label': expected $want, got $got" ;;
  esac
}

# Checks one simulated decision for what terraform-boundary lets terraform-workout do at most: an identity
# policy that allows everything is capped by the boundary. This works before the feature's own terraform-*
# policy exists (the real user's policies are not part of this check).
expect_boundary_decision() {
  local want="$1" action="$2" resource="$3" label="$4" got
  shift 4
  got=$(aws iam simulate-custom-policy     --policy-input-list '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"*","Resource":"*"}]}'     --permissions-boundary-policy-input-list "$BOUNDARY"     --action-names "$action" --resource-arns "$resource" "$@"     --query 'EvaluationResults[0].EvalDecision' --output text)
  case "$want:$got" in
    allowed:allowed | denied:explicitDeny | denied:implicitDeny) say "check: boundary $label ($got)" ;;
    *) fail "check 'boundary $label': expected $want, got $got" ;;
  esac
}

# Checks one simulated decision for a server user: even an inline policy that allows everything gets
# only what the server user boundary allows.
expect_server_user_decision() {
  local want="$1" action="$2" resource="$3" label="$4" got
  shift 4
  got=$(aws iam simulate-custom-policy \
    --policy-input-list '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"*","Resource":"*"}]}' \
    --permissions-boundary-policy-input-list "$SERVER_USER_BOUNDARY" \
    --action-names "$action" --resource-arns "$resource" "$@" \
    --query 'EvaluationResults[0].EvalDecision' --output text)
  case "$want:$got" in
    allowed:allowed | denied:explicitDeny | denied:implicitDeny) say "check: server user $label ($got)" ;;
    *) fail "check 'server user $label': expected $want, got $got" ;;
  esac
}

# --- 0. Who and where -------------------------------------------------------------------------
CALLER=$(aws sts get-caller-identity --query Arn --output text)
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
case "$CALLER" in
  */"$TF_USER") fail "run this as root or an administrator, not as $TF_USER" ;;
esac
say "signed in as someone other than $TF_USER"

USER_ARN=$(aws iam get-user --user-name "$TF_USER" --query User.Arn --output text) \
  || fail "user $TF_USER not found (create it first, docs/operations.md 1-2 step 1)"
say "user $TF_USER exists"

BOUNDARY_ARN="arn:aws:iam::${ACCOUNT}:policy/terraform-boundary"
SELF_ARN="arn:aws:iam::${ACCOUNT}:policy/terraform-iam-self"
ROLE_BOUNDARY_ARN="arn:aws:iam::${ACCOUNT}:policy/terraform-role-boundary"
SERVER_USER_BOUNDARY_ARN="arn:aws:iam::${ACCOUNT}:policy/terraform-server-user-boundary"
GUARDED="\"${BOUNDARY_ARN}\", \"${SELF_ARN}\", \"${ROLE_BOUNDARY_ARN}\", \"${SERVER_USER_BOUNDARY_ARN}\""
# The user may set the server user boundary on a server user (#88), but it can never change its own
# boundary or remove any user's boundary.
GUARD_STATEMENTS=$(cat <<EOF
    {
      "Sid": "KeepBoundary",
      "Effect": "Deny",
      "Action": "iam:PutUserPermissionsBoundary",
      "Resource": "arn:aws:iam::${ACCOUNT}:user/${TF_USER}"
    },
    {
      "Sid": "KeepUserBoundaries",
      "Effect": "Deny",
      "Action": "iam:DeleteUserPermissionsBoundary",
      "Resource": "*"
    },
    {
      "Sid": "KeepGuardPolicies",
      "Effect": "Deny",
      "Action": [
        "iam:CreatePolicyVersion", "iam:DeletePolicyVersion", "iam:SetDefaultPolicyVersion",
        "iam:DeletePolicy", "iam:TagPolicy", "iam:UntagPolicy"
      ],
      "Resource": [${GUARDED}]
    }
EOF
)

# --- 1. The role boundary ---------------------------------------------------------------------
# What the wiki deploy role needs (wiki.tf, aws_iam_role_policy.wiki_deploy), and nothing else. A role
# that carries it can do no more, whatever inline policy or trust policy Terraform gives it.
ROLE_BOUNDARY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListSiteFiles",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::sirloinbh-wiki-site-*"
    },
    {
      "Sid": "WriteSiteFiles",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::sirloinbh-wiki-site-*/*"
    },
    {
      "Sid": "RefreshCache",
      "Effect": "Allow",
      "Action": "cloudfront:CreateInvalidation",
      "Resource": "arn:aws:cloudfront::${ACCOUNT}:distribution/*"
    }
  ]
}
EOF
)
upsert_policy terraform-role-boundary "$ROLE_BOUNDARY"

# --- 1b. The server user boundary --------------------------------------------------------------
# What the four server users need together (#88), and nothing else: the inline policies in backup.tf,
# dns.tf, secrets.tf and files.tf. A server key can do no more, whatever inline policy Terraform writes.
# The app keys are SecureString parameters under the AWS managed key alias/aws/ssm. Its key policy
# allows any principal of the account through SSM (Principal "*"), which a permissions boundary
# still caps, so the boundary must allow kms:Decrypt through SSM or GetParameter fails to decrypt.
ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "${ROOT_DOMAIN}." \
  --query "HostedZones[?Name=='${ROOT_DOMAIN}.' && Config.PrivateZone==\`false\`].Id | [0]" --output text)
case "$ZONE_ID" in
  /hostedzone/*) ZONE_ID="${ZONE_ID#/hostedzone/}" ;;
  *) fail "public hosted zone ${ROOT_DOMAIN} not found" ;;
esac
say "hosted zone of ${ROOT_DOMAIN} found"
BACKUP_BUCKET="sirloinbh-db-backups-${ACCOUNT}"
FILES_BUCKET="sirloinbh-study-log-files-${ACCOUNT}"
PHOTOS_BUCKET="sirloinbh-money-ledger-photos-${ACCOUNT}"
SERVER_USER_BOUNDARY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "BackupPut",
      "Effect": "Allow",
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::${BACKUP_BUCKET}/*"
    },
    {
      "Sid": "CertbotFindZone",
      "Effect": "Allow",
      "Action": "route53:ListHostedZones",
      "Resource": "*"
    },
    {
      "Sid": "CertbotWaitForChange",
      "Effect": "Allow",
      "Action": "route53:GetChange",
      "Resource": "arn:aws:route53:::change/*"
    },
    {
      "Sid": "CertbotChallengeRecord",
      "Effect": "Allow",
      "Action": "route53:ChangeResourceRecordSets",
      "Resource": "arn:aws:route53:::hostedzone/${ZONE_ID}",
      "Condition": {
        "Null": { "route53:ChangeResourceRecordSetsNormalizedRecordNames": "false" },
        "ForAllValues:StringEquals": {
          "route53:ChangeResourceRecordSetsNormalizedRecordNames": ["_acme-challenge.${ROOT_DOMAIN}"],
          "route53:ChangeResourceRecordSetsRecordTypes": ["TXT"]
        }
      }
    },
    {
      "Sid": "ReadAppKeys",
      "Effect": "Allow",
      "Action": "ssm:GetParameter",
      "Resource": "arn:aws:ssm:${REGION}:${ACCOUNT}:parameter/sirloinbh/*"
    },
    {
      "Sid": "DecryptAppKeysThroughSsm",
      "Effect": "Allow",
      "Action": "kms:Decrypt",
      "Resource": "arn:aws:kms:${REGION}:${ACCOUNT}:key/*",
      "Condition": { "StringEquals": { "kms:ViaService": "ssm.${REGION}.amazonaws.com" } }
    },
    {
      "Sid": "StudyLogFiles",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::${FILES_BUCKET}/*"
    },
    {
      "Sid": "StudyLogFilesList",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::${FILES_BUCKET}"
    },
    {
      "Sid": "MoneyLedgerPhotos",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::${PHOTOS_BUCKET}/*"
    },
    {
      "Sid": "MoneyLedgerPhotosList",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::${PHOTOS_BUCKET}"
    },
    {
      "Sid": "StudyLogMail",
      "Effect": "Allow",
      "Action": "ses:SendEmail",
      "Resource": "arn:aws:ses:${REGION}:${ACCOUNT}:identity/*"
    },
    {
      "Sid": "UptimeMetrics",
      "Effect": "Allow",
      "Action": "cloudwatch:PutMetricData",
      "Resource": "*",
      "Condition": { "StringEquals": { "cloudwatch:namespace": "${UPTIME_NAMESPACE}" } }
    },
    {
      "Sid": "UptimeSignals",
      "Effect": "Allow",
      "Action": "sns:Publish",
      "Resource": "arn:aws:sns:${REGION}:${ACCOUNT}:${UPTIME_TOPIC}"
    }
  ]
}
EOF
)
upsert_policy terraform-server-user-boundary "$SERVER_USER_BOUNDARY"

# --- 2. The user's boundary -------------------------------------------------------------------
# Services this repo uses. IAM is limited to the resources Terraform manages: the server users
# (sirloinbh-apps-*), the wiki deploy role and its OIDC provider, the terraform-* policies, and itself.
BOUNDARY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Services",
      "Effect": "Allow",
      "Action": ["lightsail:*", "route53:*", "budgets:*", "cloudfront:*", "acm:*"],
      "Resource": "*"
    },
    {
      "Sid": "Buckets",
      "Effect": "Allow",
      "Action": "s3:*",
      "Resource": ["arn:aws:s3:::sirloinbh-*", "arn:aws:s3:::sirloinbh-*/*"]
    },
    {
      "Sid": "Parameters",
      "Effect": "Allow",
      "Action": "ssm:*",
      "Resource": "arn:aws:ssm:*:${ACCOUNT}:parameter/sirloinbh/*"
    },
    { "Sid": "ParameterList", "Effect": "Allow", "Action": "ssm:DescribeParameters", "Resource": "*" },
    {
      "Sid": "AlertTopics",
      "Effect": "Allow",
      "Action": "sns:*",
      "Resource": ["arn:aws:sns:*:${ACCOUNT}:sirloinbh-*", "arn:aws:sns:*:${ACCOUNT}:workout-memo-*"]
    },
    { "Sid": "AlertTopicList", "Effect": "Allow", "Action": ["sns:ListTopics", "sns:ListSubscriptions"], "Resource": "*" },
    {
      "Sid": "Alarms",
      "Effect": "Allow",
      "Action": "cloudwatch:*",
      "Resource": ["arn:aws:cloudwatch:*:${ACCOUNT}:alarm:sirloinbh-*", "arn:aws:cloudwatch:*:${ACCOUNT}:alarm:workout-memo-*"]
    },
    { "Sid": "AlarmRead", "Effect": "Allow", "Action": ["cloudwatch:DescribeAlarms", "cloudwatch:ListTagsForResource"], "Resource": "*" },
    {
      "Sid": "CostAnomalies",
      "Effect": "Allow",
      "Action": "ce:*",
      "Resource": ["arn:aws:ce::${ACCOUNT}:anomalymonitor/*", "arn:aws:ce::${ACCOUNT}:anomalysubscription/*"]
    },
    { "Sid": "CostAnomalyCreate", "Effect": "Allow", "Action": ["ce:CreateAnomalyMonitor", "ce:CreateAnomalySubscription"], "Resource": "*" },
    { "Sid": "CostAnomalyRead", "Effect": "Allow", "Action": ["ce:Get*", "ce:List*"], "Resource": "*" },
    {
      "Sid": "MailIdentities",
      "Effect": "Allow",
      "Action": [
        "ses:CreateEmailIdentity", "ses:DeleteEmailIdentity", "ses:GetEmailIdentity",
        "ses:PutEmailIdentityDkimAttributes", "ses:PutEmailIdentityDkimSigningAttributes",
        "ses:PutEmailIdentityFeedbackAttributes", "ses:PutEmailIdentityMailFromAttributes",
        "ses:PutEmailIdentityConfigurationSetAttributes",
        "ses:ListTagsForResource", "ses:TagResource", "ses:UntagResource"
      ],
      "Resource": "arn:aws:ses:*:${ACCOUNT}:identity/*"
    },
    {
      "Sid": "AuditTrail",
      "Effect": "Allow",
      "Action": "cloudtrail:*",
      "Resource": ["arn:aws:cloudtrail:*:${ACCOUNT}:trail/sirloinbh-*", "arn:aws:cloudtrail:*:${ACCOUNT}:trail/workout-memo-*"]
    },
    { "Sid": "AuditTrailRead", "Effect": "Allow", "Action": ["cloudtrail:DescribeTrails", "cloudtrail:ListTags"], "Resource": "*" },
    {
      "Sid": "AccountPublicAccessBlock",
      "Effect": "Allow",
      "Action": ["s3:GetAccountPublicAccessBlock", "s3:PutAccountPublicAccessBlock"],
      "Resource": "*"
    },
    {
      "Sid": "ServerUsers",
      "Effect": "Allow",
      "Action": [
        "iam:DeleteUser", "iam:GetUser", "iam:UpdateUser", "iam:TagUser", "iam:UntagUser", "iam:ListUserTags",
        "iam:GetUserPolicy", "iam:DeleteUserPolicy", "iam:ListUserPolicies",
        "iam:ListAttachedUserPolicies", "iam:ListAccessKeys", "iam:ListGroupsForUser"
      ],
      "Resource": "arn:aws:iam::${ACCOUNT}:user/sirloinbh-apps-*"
    },
    {
      "Sid": "ServerUsersWithBoundary",
      "Effect": "Allow",
      "Action": ["iam:CreateUser", "iam:PutUserPolicy", "iam:PutUserPermissionsBoundary"],
      "Resource": "arn:aws:iam::${ACCOUNT}:user/sirloinbh-apps-*",
      "Condition": { "StringEquals": { "iam:PermissionsBoundary": "${SERVER_USER_BOUNDARY_ARN}" } }
    },
    {
      "Sid": "GitHubOidcProvider",
      "Effect": "Allow",
      "Action": [
        "iam:CreateOpenIDConnectProvider", "iam:GetOpenIDConnectProvider", "iam:DeleteOpenIDConnectProvider",
        "iam:TagOpenIDConnectProvider", "iam:UntagOpenIDConnectProvider", "iam:ListOpenIDConnectProviders",
        "iam:AddClientIDToOpenIDConnectProvider", "iam:UpdateOpenIDConnectProviderThumbprint"
      ],
      "Resource": "*"
    },
    {
      "Sid": "WikiDeployRole",
      "Effect": "Allow",
      "Action": [
        "iam:GetRole", "iam:DeleteRole", "iam:UpdateRole", "iam:UpdateAssumeRolePolicy",
        "iam:TagRole", "iam:UntagRole", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
        "iam:ListInstanceProfilesForRole", "iam:GetRolePolicy", "iam:DeleteRolePolicy"
      ],
      "Resource": "arn:aws:iam::${ACCOUNT}:role/sirloinbh-wiki-*"
    },
    {
      "Sid": "WikiDeployRoleWithBoundary",
      "Effect": "Allow",
      "Action": ["iam:CreateRole", "iam:PutRolePolicy", "iam:PutRolePermissionsBoundary"],
      "Resource": "arn:aws:iam::${ACCOUNT}:role/sirloinbh-wiki-*",
      "Condition": { "StringEquals": { "iam:PermissionsBoundary": "${ROLE_BOUNDARY_ARN}" } }
    },
    {
      "Sid": "TerraformPolicies",
      "Effect": "Allow",
      "Action": [
        "iam:CreatePolicy", "iam:CreatePolicyVersion", "iam:DeletePolicy", "iam:DeletePolicyVersion",
        "iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicyVersions", "iam:ListPolicyTags",
        "iam:ListEntitiesForPolicy", "iam:SetDefaultPolicyVersion", "iam:TagPolicy", "iam:UntagPolicy"
      ],
      "Resource": "arn:aws:iam::${ACCOUNT}:policy/terraform-*"
    },
    {
      "Sid": "OwnUser",
      "Effect": "Allow",
      "Action": ["iam:GetUser", "iam:List*", "iam:AttachUserPolicy", "iam:DetachUserPolicy"],
      "Resource": "arn:aws:iam::${ACCOUNT}:user/${TF_USER}"
    },
    {
      "Sid": "OnlyTerraformPolicies",
      "Effect": "Deny",
      "Action": ["iam:AttachUserPolicy", "iam:AttachRolePolicy", "iam:AttachGroupPolicy"],
      "Resource": "*",
      "Condition": { "ArnNotLike": { "iam:PolicyARN": "arn:aws:iam::${ACCOUNT}:policy/terraform-*" } }
    },
    {
      "Sid": "OnlyBoundedRoles",
      "Effect": "Deny",
      "Action": ["iam:CreateRole", "iam:PutRolePolicy", "iam:AttachRolePolicy", "iam:PutRolePermissionsBoundary"],
      "Resource": "*",
      "Condition": { "StringNotEquals": { "iam:PermissionsBoundary": "${ROLE_BOUNDARY_ARN}" } }
    },
    {
      "Sid": "OnlyBoundedServerUsers",
      "Effect": "Deny",
      "Action": ["iam:CreateUser", "iam:PutUserPolicy", "iam:AttachUserPolicy", "iam:PutUserPermissionsBoundary"],
      "Resource": "arn:aws:iam::${ACCOUNT}:user/sirloinbh-apps-*",
      "Condition": { "StringNotEquals": { "iam:PermissionsBoundary": "${SERVER_USER_BOUNDARY_ARN}" } }
    },
    {
      "Sid": "KeepRoleBoundary",
      "Effect": "Deny",
      "Action": "iam:DeleteRolePermissionsBoundary",
      "Resource": "*"
    },
    {
      "Sid": "NoAssumeRole",
      "Effect": "Deny",
      "Action": "sts:AssumeRole",
      "Resource": "*"
    },
${GUARD_STATEMENTS}
  ]
}
EOF
)
upsert_policy terraform-boundary "$BOUNDARY"

# --- 3. Set the boundary before any self-management right exists -------------------------------
if [ "$(aws iam get-user --user-name "$TF_USER" --query 'User.PermissionsBoundary.PermissionsBoundaryArn' --output text)" = "$BOUNDARY_ARN" ]; then
  say "boundary already set on $TF_USER"
else
  aws iam put-user-permissions-boundary --user-name "$TF_USER" --permissions-boundary "$BOUNDARY_ARN"
  say "boundary set on $TF_USER"
fi

# --- 4. The self-management policy -----------------------------------------------------------
IAM_SELF=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TerraformPolicies",
      "Effect": "Allow",
      "Action": [
        "iam:CreatePolicy", "iam:CreatePolicyVersion", "iam:DeletePolicy", "iam:DeletePolicyVersion",
        "iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicyVersions", "iam:ListPolicyTags",
        "iam:ListEntitiesForPolicy", "iam:SetDefaultPolicyVersion", "iam:TagPolicy", "iam:UntagPolicy"
      ],
      "Resource": "arn:aws:iam::${ACCOUNT}:policy/terraform-*"
    },
    {
      "Sid": "AttachOnlyToSelf",
      "Effect": "Allow",
      "Action": ["iam:AttachUserPolicy", "iam:DetachUserPolicy"],
      "Resource": "arn:aws:iam::${ACCOUNT}:user/${TF_USER}",
      "Condition": { "ArnLike": { "iam:PolicyARN": "arn:aws:iam::${ACCOUNT}:policy/terraform-*" } }
    },
    {
      "Sid": "BoundServerUsers",
      "Effect": "Allow",
      "Action": "iam:PutUserPermissionsBoundary",
      "Resource": "arn:aws:iam::${ACCOUNT}:user/sirloinbh-apps-*",
      "Condition": { "StringEquals": { "iam:PermissionsBoundary": "${SERVER_USER_BOUNDARY_ARN}" } }
    },
    {
      "Sid": "ReadSelf",
      "Effect": "Allow",
      "Action": ["iam:GetUser", "iam:ListAttachedUserPolicies", "iam:ListUserPolicies", "iam:ListUserTags", "iam:ListGroupsForUser"],
      "Resource": "arn:aws:iam::${ACCOUNT}:user/${TF_USER}"
    },
${GUARD_STATEMENTS}
  ]
}
EOF
)
upsert_policy terraform-iam-self "$IAM_SELF"

# --- 5. Attach it ----------------------------------------------------------------------------
if aws iam list-attached-user-policies --user-name "$TF_USER" \
    --query "AttachedPolicies[?PolicyArn=='${SELF_ARN}'].PolicyArn" --output text | grep -q .; then
  say "terraform-iam-self already attached to $TF_USER"
else
  aws iam attach-user-policy --user-name "$TF_USER" --policy-arn "$SELF_ARN"
  say "terraform-iam-self attached to $TF_USER"
fi

# --- 6. Check the result with the IAM policy simulator ---------------------------------------
STATE_POLICY="arn:aws:iam::${ACCOUNT}:policy/terraform-state"
expect_decision allowed iam:CreatePolicyVersion "$STATE_POLICY" "can version terraform-* policies"
expect_decision allowed iam:AttachUserPolicy "$USER_ARN" "can attach a terraform-* policy to itself" \
  --context-entries "ContextKeyName=iam:PolicyARN,ContextKeyValues=${STATE_POLICY},ContextKeyType=string"
expect_decision denied iam:AttachUserPolicy "$USER_ARN" "cannot attach AdministratorAccess" \
  --context-entries "ContextKeyName=iam:PolicyARN,ContextKeyValues=arn:aws:iam::aws:policy/AdministratorAccess,ContextKeyType=string"
expect_decision denied iam:DeleteUserPermissionsBoundary "$USER_ARN" "cannot remove its boundary"
expect_decision denied iam:CreatePolicyVersion "$BOUNDARY_ARN" "cannot edit terraform-boundary"
expect_decision denied iam:CreatePolicyVersion "$SELF_ARN" "cannot edit terraform-iam-self"
expect_decision denied iam:CreatePolicyVersion "$ROLE_BOUNDARY_ARN" "cannot edit terraform-role-boundary"
WIKI_ROLE="arn:aws:iam::${ACCOUNT}:role/sirloinbh-wiki-deploy"
expect_decision denied iam:CreateRole "$WIKI_ROLE" "cannot create a wiki role without the role boundary"
expect_decision denied iam:CreateRole "$WIKI_ROLE" "cannot create a wiki role with another boundary"   --context-entries "ContextKeyName=iam:PermissionsBoundary,ContextKeyValues=${BOUNDARY_ARN},ContextKeyType=string"
expect_decision allowed iam:CreateRole "$WIKI_ROLE" "can create a wiki role with the role boundary"   --context-entries "ContextKeyName=iam:PermissionsBoundary,ContextKeyValues=${ROLE_BOUNDARY_ARN},ContextKeyType=string"
expect_decision denied iam:PutRolePolicy "$WIKI_ROLE" "cannot write the policy of a role without the role boundary"
expect_decision denied iam:DeleteRolePermissionsBoundary "$WIKI_ROLE" "cannot remove a role's boundary"

# Server users (#88).
WITH_SERVER_BOUNDARY="ContextKeyName=iam:PermissionsBoundary,ContextKeyValues=${SERVER_USER_BOUNDARY_ARN},ContextKeyType=string"
WITH_OTHER_BOUNDARY="ContextKeyName=iam:PermissionsBoundary,ContextKeyValues=${ROLE_BOUNDARY_ARN},ContextKeyType=string"
expect_decision denied iam:PutUserPermissionsBoundary "$USER_ARN" "cannot change its boundary" \
  --context-entries "$WITH_SERVER_BOUNDARY"
expect_decision denied iam:CreatePolicyVersion "$SERVER_USER_BOUNDARY_ARN" "cannot edit terraform-server-user-boundary"
SERVER_USER="arn:aws:iam::${ACCOUNT}:user/sirloinbh-apps-secrets-reader"
expect_decision denied iam:PutUserPolicy "$SERVER_USER" "cannot write a server user policy without the server user boundary"
expect_decision denied iam:PutUserPolicy "$SERVER_USER" "cannot write a server user policy with another boundary" \
  --context-entries "$WITH_OTHER_BOUNDARY"
expect_decision allowed iam:PutUserPolicy "$SERVER_USER" "can write a server user policy with the server user boundary" \
  --context-entries "$WITH_SERVER_BOUNDARY"
expect_decision denied iam:CreateUser "$SERVER_USER" "cannot create a server user without the server user boundary"
expect_decision allowed iam:CreateUser "$SERVER_USER" "can create a server user with the server user boundary" \
  --context-entries "$WITH_SERVER_BOUNDARY"
expect_decision denied iam:PutUserPermissionsBoundary "$SERVER_USER" "cannot give a server user another boundary" \
  --context-entries "$WITH_OTHER_BOUNDARY"
expect_decision allowed iam:PutUserPermissionsBoundary "$SERVER_USER" "can give a server user the server user boundary" \
  --context-entries "$WITH_SERVER_BOUNDARY"
expect_decision denied iam:DeleteUserPermissionsBoundary "$SERVER_USER" "cannot remove a server user's boundary"
expect_decision denied iam:AttachUserPolicy "$SERVER_USER" "cannot attach a policy to a server user" \
  --context-entries "ContextKeyName=iam:PolicyARN,ContextKeyValues=${STATE_POLICY},ContextKeyType=string" "$WITH_SERVER_BOUNDARY"

# What a server user can do under its boundary, even with an inline policy that allows everything.
ZONE_ARN="arn:aws:route53:::hostedzone/${ZONE_ID}"
RECORD_NAMES="ContextKeyName=route53:ChangeResourceRecordSetsNormalizedRecordNames,ContextKeyType=stringList"
RECORD_TYPES="ContextKeyName=route53:ChangeResourceRecordSetsRecordTypes,ContextKeyType=stringList"
expect_server_user_decision allowed s3:PutObject "arn:aws:s3:::${BACKUP_BUCKET}/x" "can upload a backup"
expect_server_user_decision denied s3:GetObject "arn:aws:s3:::${BACKUP_BUCKET}/x" "cannot read a backup"
expect_server_user_decision allowed route53:ChangeResourceRecordSets "$ZONE_ARN" "can write the certbot TXT record" \
  --context-entries "${RECORD_NAMES},ContextKeyValues=_acme-challenge.${ROOT_DOMAIN}" "${RECORD_TYPES},ContextKeyValues=TXT"
expect_server_user_decision denied route53:ChangeResourceRecordSets "$ZONE_ARN" "cannot change an app record" \
  --context-entries "${RECORD_NAMES},ContextKeyValues=${ROOT_DOMAIN}" "${RECORD_TYPES},ContextKeyValues=A"
expect_server_user_decision allowed ssm:GetParameter "arn:aws:ssm:${REGION}:${ACCOUNT}:parameter/sirloinbh/shared/x" "can read an app key"
expect_server_user_decision denied ssm:PutParameter "arn:aws:ssm:${REGION}:${ACCOUNT}:parameter/sirloinbh/shared/x" "cannot write an app key"
KMS_KEY="arn:aws:kms:${REGION}:${ACCOUNT}:key/00000000-0000-0000-0000-000000000000"
expect_server_user_decision allowed kms:Decrypt "$KMS_KEY" "can decrypt an app key through SSM"   --context-entries "ContextKeyName=kms:ViaService,ContextKeyValues=ssm.${REGION}.amazonaws.com,ContextKeyType=string"
expect_server_user_decision denied kms:Decrypt "$KMS_KEY" "cannot decrypt outside SSM"
expect_server_user_decision allowed s3:DeleteObject "arn:aws:s3:::${FILES_BUCKET}/x" "can delete a study-log file"
expect_server_user_decision allowed s3:ListBucket "arn:aws:s3:::${FILES_BUCKET}" "can list the study-log files"
expect_server_user_decision denied s3:PutBucketVersioning "arn:aws:s3:::${FILES_BUCKET}" "cannot change the study-log files bucket"
expect_server_user_decision allowed s3:PutObject "arn:aws:s3:::${PHOTOS_BUCKET}/x" "can put a money-ledger photo"
expect_server_user_decision allowed s3:ListBucket "arn:aws:s3:::${PHOTOS_BUCKET}" "can list the money-ledger photos"
expect_server_user_decision denied s3:PutBucketVersioning "arn:aws:s3:::${PHOTOS_BUCKET}" "cannot change the money-ledger photos bucket"
MAIL_IDENTITY="arn:aws:ses:${REGION}:${ACCOUNT}:identity/reminder@example.com"
expect_server_user_decision allowed ses:SendEmail "$MAIL_IDENTITY" "can send email from an identity"
expect_server_user_decision denied ses:SendRawEmail "$MAIL_IDENTITY" "cannot send raw email"
expect_server_user_decision denied ses:CreateEmailIdentity "$MAIL_IDENTITY" "cannot create an email identity"
expect_server_user_decision denied ses:SendEmail "arn:aws:ses:us-east-1:${ACCOUNT}:identity/reminder@example.com" "cannot send through another region"
expect_server_user_decision denied iam:CreateUser "$SERVER_USER" "cannot use IAM"
NAMESPACE_KEY="ContextKeyName=cloudwatch:namespace,ContextKeyType=string"
expect_server_user_decision allowed cloudwatch:PutMetricData "*" "can put uptime metrics"   --context-entries "${NAMESPACE_KEY},ContextKeyValues=${UPTIME_NAMESPACE}"
expect_server_user_decision denied cloudwatch:PutMetricData "*" "cannot put metrics in another namespace"   --context-entries "${NAMESPACE_KEY},ContextKeyValues=AWS/EC2"
expect_server_user_decision allowed sns:Publish "arn:aws:sns:${REGION}:${ACCOUNT}:${UPTIME_TOPIC}" "can publish to the uptime topic"
expect_server_user_decision denied sns:Publish "arn:aws:sns:${REGION}:${ACCOUNT}:other-topic" "cannot publish to another topic"
expect_server_user_decision denied sns:Subscribe "arn:aws:sns:${REGION}:${ACCOUNT}:${UPTIME_TOPIC}" "cannot subscribe to the uptime topic"
expect_server_user_decision denied cloudwatch:PutMetricAlarm "arn:aws:cloudwatch:${REGION}:${ACCOUNT}:alarm:sirloinbh-uptime-heartbeat" "cannot change an alarm"

# Alert and guard rail services (#98). The boundary names stay inside sirloinbh-* and workout-memo-*.
ALERT_TOPIC="arn:aws:sns:${REGION}:${ACCOUNT}:sirloinbh-uptime-alerts"
ALERT_ALARM="arn:aws:cloudwatch:${REGION}:${ACCOUNT}:alarm:sirloinbh-uptime-heartbeat"
expect_boundary_decision allowed sns:CreateTopic "$ALERT_TOPIC" "can create the alert topic"
expect_boundary_decision allowed sns:Subscribe "$ALERT_TOPIC" "can subscribe an email to the alert topic"
expect_boundary_decision denied sns:CreateTopic "arn:aws:sns:${REGION}:${ACCOUNT}:other-topic" "cannot create a topic outside sirloinbh-*"
expect_boundary_decision allowed cloudwatch:PutMetricAlarm "$ALERT_ALARM" "can create an alarm"
expect_boundary_decision denied cloudwatch:PutMetricAlarm "arn:aws:cloudwatch:${REGION}:${ACCOUNT}:alarm:other-alarm" "cannot create an alarm outside sirloinbh-*"
expect_boundary_decision allowed cloudwatch:DescribeAlarms "*" "can read alarms"
expect_boundary_decision allowed ce:CreateAnomalyMonitor "*" "can create a cost anomaly monitor"
expect_boundary_decision allowed ce:CreateAnomalySubscription "*" "can create a cost anomaly subscription"
expect_boundary_decision allowed ce:DeleteAnomalyMonitor "arn:aws:ce::${ACCOUNT}:anomalymonitor/x" "can delete a cost anomaly monitor"
expect_boundary_decision allowed cloudtrail:CreateTrail "arn:aws:cloudtrail:${REGION}:${ACCOUNT}:trail/sirloinbh-audit" "can create a trail"
expect_boundary_decision denied cloudtrail:CreateTrail "arn:aws:cloudtrail:${REGION}:${ACCOUNT}:trail/other-trail" "cannot create a trail outside sirloinbh-*"
expect_boundary_decision allowed ses:CreateEmailIdentity "$MAIL_IDENTITY" "can create an email identity"
expect_boundary_decision allowed ses:GetEmailIdentity "$MAIL_IDENTITY" "can read an email identity"
expect_boundary_decision denied ses:SendEmail "$MAIL_IDENTITY" "cannot send email itself"
expect_boundary_decision allowed s3:PutAccountPublicAccessBlock "*" "can set the account public access block"
expect_boundary_decision allowed s3:GetAccountPublicAccessBlock "*" "can read the account public access block"
expect_boundary_decision denied sqs:CreateQueue "arn:aws:sqs:${REGION}:${ACCOUNT}:sirloinbh-x" "cannot use a service outside the list"

say "bootstrap finished"

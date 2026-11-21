#!/usr/bin/env bash
# One-time bootstrap that lets Terraform manage its own IAM policies (#79) and caps the roles it
# creates (#85). Steps are in docs/operations.md 1-2.
# Run it in AWS CloudShell of the personal account, signed in as root or an administrator, not as
# terraform-workout. It is safe to run again: each step changes AWS only when it differs from below.
#
#   1. Policy `terraform-role-boundary`: the most a role that terraform-workout creates can ever do
#      (upload the wiki site and clear its cache). terraform-boundary lets the user create a role,
#      write its policy, or set its boundary only with this boundary, and never remove it (#85).
#   2. Policy `terraform-boundary`: the most terraform-workout can ever do. It is set as the user's
#      permissions boundary, so every policy Terraform writes for itself is capped by it.
#   3. Policy `terraform-iam-self`: lets terraform-workout create, version and delete policies named
#      `terraform-*` and attach them only to itself.
#   All three are guarded: the user cannot edit or delete them or remove its own boundary, so
#   Terraform cannot widen either cap.
set -euo pipefail
export AWS_PAGER=""

TF_USER="terraform-workout"

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
GUARDED="\"${BOUNDARY_ARN}\", \"${SELF_ARN}\", \"${ROLE_BOUNDARY_ARN}\""
GUARD_STATEMENTS=$(cat <<EOF
    {
      "Sid": "KeepBoundary",
      "Effect": "Deny",
      "Action": ["iam:PutUserPermissionsBoundary", "iam:DeleteUserPermissionsBoundary"],
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
      "Sid": "ServerUsers",
      "Effect": "Allow",
      "Action": [
        "iam:CreateUser", "iam:DeleteUser", "iam:GetUser", "iam:UpdateUser", "iam:TagUser", "iam:UntagUser", "iam:ListUserTags",
        "iam:PutUserPolicy", "iam:GetUserPolicy", "iam:DeleteUserPolicy", "iam:ListUserPolicies",
        "iam:ListAttachedUserPolicies", "iam:ListAccessKeys", "iam:ListGroupsForUser"
      ],
      "Resource": "arn:aws:iam::${ACCOUNT}:user/sirloinbh-apps-*"
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

say "bootstrap finished"

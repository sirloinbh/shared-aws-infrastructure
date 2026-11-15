# Shared AWS Infrastructure Instructions

This repo manages, with Terraform, the infrastructure of the personal AWS account that several apps share. **Always read and follow [AGENTS.project.md](AGENTS.project.md) together with this file for this repo's resources and operating rules.** If the two files differ, AGENTS.project.md wins.

## Work procedure

Follow std-backlog to split requirements into issues and to choose the next task, and std-git-writing to write issues, branches, commits, and PRs (the source is `templates/common/skills/` in `sirloinbh/project-standards`).

1. Register an issue in `sirloinbh/shared-aws-infrastructure`. If the user named an existing issue, reuse it.
2. Create a work branch that contains the issue number: `<type>/<issue-number>-<slug>`.
3. Run the verification commands below before committing and before creating or updating a PR, and record the results in the PR.
4. **The agent reviews and merges its own PRs** (user decision, 2026-11-15, #46).
   - Review the PR with std-code-review 1–2 times, fixing findings on the same branch, until no blocking finding remains.
   - If a review finds a big problem outside the PR's scope, register it as a new issue (std-backlog) instead of growing the PR.
   - When the review passes and CI is green, merge with `pr merge --merge` (no `--delete-branch`, no squash), then clean up the local branch as in std-git-writing.
   - Do not merge, and ask the user, when "Check before merging" has an item that needs the user's decision. Merging is not applying: real AWS changes still follow "plan and apply" in [AGENTS.project.md](AGENTS.project.md).

Answering questions, giving recommendations, and read-only investigation do not create an issue or a branch.

## Prohibited actions

- Do not commit Terraform state, `terraform.tfvars`, plan files, AWS keys, or SSH private keys, and do not record them in docs, PRs, issues, or logs. Do not write account IDs, allowed IPs, or email addresses in documents either.
- Do not push directly to `main` or force-push.
- Do not plan or apply with a company AWS profile or the default profile.
- Do not overwrite user changes. Stage only the files you need, by name.
- Do GitHub remote work with the personal account `sirloinbh`. Do not make remote changes with a company account.

## Verification commands

```sh
terraform fmt -check -recursive
terraform init -backend=false -input=false
terraform validate
bash -n user-data.sh
```

- CI (`.github/workflows/ci.yml`) runs the same checks. CI does not run `terraform apply`.
- Do not mark the command of a tool you have not installed yet as runnable.

<!-- Managed file. Edit it in sirloinbh/project-standards templates/infra/ -->
# Shared AWS Infrastructure Instructions

This repo manages, with Terraform, the infrastructure of the personal AWS account that several apps share. **Always read and follow [AGENTS.project.md](AGENTS.project.md) together with this file for this repo's resources and operating rules.** If the two files differ, AGENTS.project.md wins.

## Work procedure

To split requirements into issues and to choose the next task, follow [std-backlog](skills/std-backlog/SKILL.md). To write issues, branches, commits, and PRs, follow [std-git-writing](skills/std-git-writing/SKILL.md); to change code, docs, or config, follow [std-implementation](skills/std-implementation/SKILL.md); to review a PR, follow [std-code-review](skills/std-code-review/SKILL.md). Write explanations to the user in English, as [std-communication](skills/std-communication/SKILL.md) says. Keep progress, decisions, and next steps in md files, not in the chat or memory, as [std-session-notes](skills/std-session-notes/SKILL.md) says.

1. Register an issue in `sirloinbh/shared-aws-infrastructure`. If the user named an existing issue, reuse it.
2. Create a work branch that contains the issue number: `<type>/<issue-number>-<slug>`.
3. Run the verification commands below before committing and before creating or updating a PR, and record the results in the PR.
4. **The agent reviews and merges its own PRs** (user decision, 2026-11-15, `sirloinbh/project-standards#591`).
   - Review the PR with std-code-review section 8, 1 or 2 times, fixing findings on the same branch, until no blocking finding remains.
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

## Centrally managed files

- Files whose first line says "Managed file" and files listed in `.standards/manifest.json` are managed by `sirloinbh/project-standards`. This file is one of them. If you edit them directly in this repo, the CI `standards-check` fails. Raise the change in the central repo with an issue and a PR.
- In files that have a `# --- project ---` line, such as `.gitignore`, this repo may edit only below that line.
- Sync PRs never change `.tf`, `.tfvars`, or `.sh` files and never run `terraform apply`.

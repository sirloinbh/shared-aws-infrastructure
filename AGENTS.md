# 공유 AWS 인프라 지침

여러 앱이 함께 쓰는 개인 AWS 계정의 인프라를 Terraform으로 관리하는 리포다. 이 리포의 리소스와 운영 규칙은 **[AGENTS.project.md](AGENTS.project.md)를 반드시 함께 읽고 따른다.** 두 파일이 다르면 AGENTS.project.md가 우선한다.

## 작업 절차

요구사항을 이슈로 나누고 다음 작업을 고를 때는 std-backlog, 이슈·브랜치·커밋·PR을 쓸 때는 std-git-writing을 따른다(원본: `sirloinbh/project-standards`의 `templates/common/skills/`).

1. `sirloinbh/shared-aws-infrastructure`에 이슈를 등록한다. 사용자가 지정한 기존 이슈가 있으면 재사용한다.
2. 이슈 번호를 포함한 작업 브랜치를 만든다: `<type>/<issue-number>-<slug>`.
3. 커밋 전과 PR 생성·갱신 전에 아래 검증 명령을 실행하고 결과를 PR에 적는다.
4. **PR 병합은 사용자만 한다.** 에이전트는 병합·자동 병합·승인으로 병합을 대신하지 않는다.

질문 답변·추천·읽기 전용 조사는 이슈나 브랜치를 만들지 않는다.

## 금지 사항

- Terraform state, `terraform.tfvars`, plan 파일, AWS 키, SSH 개인키는 커밋하거나 docs·PR·이슈·로그에 기록하지 않는다. 계정 ID, 허용 IP, 이메일도 문서에 적지 않는다.
- `main`에 직접 push하거나 force push하지 않는다.
- 회사 AWS 프로필이나 기본 프로필로 plan·apply하지 않는다.
- 사용자 변경을 덮어쓰지 않는다. 필요한 파일만 명시해서 stage한다.
- GitHub 원격 작업은 개인 계정 `sirloinbh`로 한다. 회사 계정으로 원격 변경을 하지 않는다.

## 검증 명령

```sh
terraform fmt -check -recursive
terraform init -backend=false -input=false
terraform validate
bash -n user-data.sh
```

- CI(`.github/workflows/ci.yml`)도 같은 검사를 실행한다. CI는 `terraform apply`를 하지 않는다.
- 아직 설치하지 않은 도구의 명령을 실행 가능한 것으로 표시하지 않는다.

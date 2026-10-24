# 공유 AWS 인프라 고유 지침

이 리포에만 해당하는 규칙이다. 공통 절차는 [AGENTS.md](AGENTS.md)이며, 두 파일이 다르면 이 파일이 우선한다.

## 관리 대상

- 개인 AWS 계정, 서울 리전(`ap-northeast-2`)의 workout-memo 운영 서버: Lightsail 인스턴스, 고정 IP와 연결, SSH 키 쌍, 방화벽, 월 예산 알림. 구성과 비용은 [운영 문서](docs/operations.md)에 있다.
- 리소스 이름은 `var.project` 접두어(`workout-memo-*`)를 쓴다. 다른 앱을 추가하면 접두어로 구분한다.
- 앱 배포·롤백·자동 배포·DB 백업은 각 앱 리포가 관리한다(workout-memo `docs/deployment.md`).

## plan과 apply

- 실제 AWS 변경은 **사용자가 요청한 범위에서만** 한다. 개인 계정 프로필(`aws_profile`, `expected_account_id`)로 `terraform plan -out=<파일>`을 만들고, 결과를 사용자에게 보여 확인받은 뒤 그 plan 파일로 apply한다.
- plan에 교체(`-/+`)나 삭제가 있으면 apply하지 않고 원인과 영향을 먼저 보고한다. 고정 IP를 다시 만들면 공인 주소가 바뀐다.
- `user_data`는 `ignore_changes`다. 바꿔도 기존 서버에는 적용되지 않으므로, 기존 서버에 필요한 변경은 앱 리포의 배포 스크립트로 한다.
- provider 버전을 올리면 state가 새 형식으로 저장되어 되돌릴 수 없다. 버전 변경 PR을 먼저 병합한 뒤 apply한다.
- remote backend가 없다. state는 apply한 PC의 이 폴더에만 있으므로 apply 뒤에는 리포 밖에 백업한다. 잃었을 때는 [운영 문서](docs/operations.md)의 import 절차를 따른다.

## 버전

- Terraform CLI와 Action 버전은 `sirloinbh/project-standards`의 `versions.json`을 따른다.
- AWS provider는 `versions.tf`와 `.terraform.lock.hcl`로 고정한다. 올릴 때는 릴리스 후 14일이 지난 버전을 고르고, `terraform providers lock -platform=windows_amd64 -platform=linux_amd64`로 두 플랫폼 해시를 기록한다.

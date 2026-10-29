# 공유 AWS 인프라

개인 AWS 계정의 인프라를 관리하는 Terraform 원본 리포입니다. 지금은 workout-memo 운영 서버 한 대를 관리합니다. 서울 리전의 Lightsail `micro_3_0`이며, 구성은 다음과 같습니다.

- 고정 IP
- 방화벽: 22·80 포트를 허용 IP에만 개방
- 자동 스냅샷: 매일 03:00(서울), AWS가 최근 7개 보관
- 월 $10 예산 알림: 실제 지출 50%·80%, 예상 지출 100%

서버 초기화는 `user-data.sh`가 합니다. Docker·Compose 설치, swap 2GB, 앱 저장소 clone, DB 비밀번호 생성, 매일 DB 덤프(14일 보관)를 설정합니다.

```sh
cp terraform.tfvars.example terraform.tfvars   # 개인 값 입력, git 제외
terraform init
terraform plan "-out=deploy.tfplan"
terraform apply deploy.tfplan
```

- `expected_account_id`와 현재 자격 증명의 계정이 다르면 plan이 실패합니다. 회사 프로필로 적용되는 것을 막습니다.
- `user_data`는 첫 부팅 때만 실행됩니다. 바꿔도 기존 인스턴스를 다시 만들지 않습니다(`ignore_changes`).
- Terraform state와 `terraform.tfvars`는 git에 저장하지 않습니다. remote backend가 없으므로 apply 뒤에 리포 밖에 백업합니다.
- 예산 알림은 지출 차단 기능이 아닙니다.

## 문서

- [인프라 운영](docs/operations.md): 준비, 적용, state 관리와 분실 시 복구, SSH 키 추가, 허용 IP 변경, 알람, 철거
- 앱 배포·롤백·자동 배포·DB 백업 복원: workout-memo `docs/deployment.md`
- 작업 지침: [AGENTS.md](AGENTS.md), [AGENTS.project.md](AGENTS.project.md)

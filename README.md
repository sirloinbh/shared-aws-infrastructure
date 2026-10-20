# Workout Memo AWS 인프라

개인 계정의 서울 리전에 Lightsail `micro_3_0` 서버 한 대를 만드는 Terraform입니다(#73). 구성은 다음과 같습니다.

- 고정 IP
- 방화벽: 22·80 포트를 허용 IP에만 개방
- 자동 스냅샷: 매일 03:00(서울), AWS가 최근 7개 보관
- 월 $10 예산 알림: 실제 지출 50%·80%, 예상 지출 100%

서버 초기화는 `user-data.sh`가 합니다. Docker·Compose 설치, swap 2GB, 저장소 clone, DB 비밀번호 생성, 매일 DB 덤프(14일 보관)를 설정합니다.

```sh
cp terraform.tfvars.example terraform.tfvars   # 개인 값 입력, git 제외
terraform init
terraform plan -out=deploy.tfplan
terraform apply deploy.tfplan
```

- `expected_account_id`와 현재 자격 증명의 계정이 다르면 plan이 실패합니다. 회사 프로필로 적용되는 것을 막습니다.
- `user_data`는 첫 부팅 때만 실행됩니다. 바꿔도 기존 인스턴스를 다시 만들지 않습니다(`ignore_changes`).
- Terraform state와 `terraform.tfvars`는 git에 저장하지 않습니다.
- 예산 알림은 지출 차단 기능이 아닙니다.

준비·배포·롤백·백업·복원·IP 변경·철거 절차는 [배포·운영 문서](../docs/deployment.md)를 따릅니다.

# 공유 AWS 인프라

서울 리전 ECR 2개(이미지 검사·최근 10개 보관)와 월 비용 80% 이메일 알림의 Terraform 초안입니다. 다른 프로젝트는 ECR `for_each`에 이름을 추가해 사용할 수 있습니다. 예산 알림은 지출 차단 기능이 아닙니다.

```sh
terraform init
terraform plan -var='budget_email=YOUR_EMAIL'
terraform apply -var='budget_email=YOUR_EMAIL'
```

실제 AWS 리소스는 아직 생성하지 않았습니다. 운영 컴퓨팅, PostgreSQL 호스팅, HTTPS, 원격 state, GitHub OIDC 및 배포 워크플로는 배포 방식과 비용 한도를 정한 후 구성해야 합니다. 로그인 없는 앱은 공개 인터넷에 그대로 노출하지 말고 VPN/사설 접속으로 운영합니다. Terraform state에는 민감정보가 들어갈 수 있으므로 Git에 저장하지 않습니다.

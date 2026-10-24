# 인프라 운영

개인 AWS 계정 서울 리전의 Lightsail 서버 한 대를 Terraform으로 만들고 관리하는 절차입니다. 서버 안의 앱 배포·롤백·자동 배포·DB 백업 복원은 앱 리포 문서(workout-memo `docs/deployment.md`)를 따릅니다.

명령은 모두 이 리포 폴더에서 실행합니다. 예시의 프로필 이름은 `workout-personal`입니다.

## 구성과 비용

| 항목 | 값 | 월 비용(세전, 추정) |
|---|---|---|
| Lightsail `micro_3_0`, 서울 | 1GB RAM, 40GB SSD, 공인 IPv4, 2TB 전송, Ubuntu 24.04 | $7.00 |
| 고정 IP | 인스턴스에 연결된 동안 | $0 |
| 자동 스냅샷 | 매일 03:00(서울), AWS가 최근 7개 보관, 사용 용량 기준 $0.05/GB-month | 약 $1 미만 |
| DB 덤프 | 매일 03:30(서울), 서버 `/var/backups/workout`에 14일 보관(스냅샷에도 포함) | $0 |
| 로그 | Docker json-file 컨테이너당 10MB×3 순환 | $0 |
| AWS Budgets | $10. 실제 지출 50%·80%, 예상 지출 100%에서 이메일 | 무료(알림만 쓰는 예산) |
| 합계 | | **약 $7~8** (VAT 10% 별도) |

- 예산 알림은 지출을 막지 않습니다. 개인 계정 전체 비용을 대상으로 합니다.
- 비용 근거: [Lightsail 요금](https://aws.amazon.com/lightsail/pricing/), [Budgets 요금](https://aws.amazon.com/aws-cost-management/aws-budgets/pricing/). 실제 청구액은 결제 시점의 요금·세금을 따릅니다.
- ECR, S3, CloudWatch Logs는 쓰지 않습니다. 비용이 늘고, 서버에 장기 AWS 키를 둬야 하기 때문입니다.
- 도메인이 없어 HTTP로 접속합니다. IP 제한은 걸리지만 전송 구간은 암호화되지 않습니다. 공용 Wi-Fi에서는 SSH 터널을 씁니다(6장).

## 1. 처음 한 번 준비

### 1-1. 도구

Terraform CLI와 AWS CLI를 설치합니다. Terraform 버전은 `sirloinbh/project-standards`의 `versions.json`(`terraform.cli`)을 따릅니다.

```powershell
winget install --id Hashicorp.Terraform --version <versions.json의 terraform.cli> --exact
winget install --id Amazon.AWSCLI --exact
```

### 1-2. AWS 자격 증명 (루트 키를 만들지 않습니다)

Terraform 전용 IAM 사용자를 만들고 그 사용자의 액세스 키를 씁니다.

1. 루트 계정으로 콘솔에 로그인 → IAM → 사용자 → 사용자 생성. 이름 예: `terraform-workout`. 콘솔 액세스는 주지 않습니다.
2. 권한 탭 → 권한 추가 → 인라인 정책 생성 → JSON:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       { "Sid": "Lightsail", "Effect": "Allow", "Action": "lightsail:*", "Resource": "*" },
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
3. 보안 자격 증명 탭 → 액세스 키 만들기 → 사용 사례 "명령줄 인터페이스(CLI)". 설명 태그에 어느 PC용인지 적습니다.
4. 회사 프로필과 섞이지 않도록 이름을 붙여 등록하고 계정을 확인합니다.
   ```powershell
   aws configure --profile workout-personal       # 리전 ap-northeast-2
   aws sts get-caller-identity --profile workout-personal
   ```
   `Arn`이 `...:user/terraform-workout`이고 `Account`가 개인 계정이면 됩니다.

키 값은 리포·채팅·이슈에 남기지 않습니다. AWS CLI가 처음 실행될 때 AI 에이전트용 스킬과 MCP 서버 설치를 물으면, 필요하지 않다면 `n`으로 답합니다.

### 1-3. SSH 키

이 서버 전용으로 PC마다 만듭니다. 개인키는 그 PC에만 둡니다.

```powershell
New-Item -ItemType Directory -Force "$HOME\.ssh" | Out-Null
ssh-keygen -t ed25519 -f "$HOME\.ssh\workout-memo-lightsail" -C "<pc이름>-workout-memo"
(Get-Content "$HOME\.ssh\workout-memo-lightsail.pub").Count   # 1 이어야 함
```

명령은 한 줄로 붙여 넣습니다. PowerShell에서 줄이 끊기면(`>>` 표시) 주석에 줄바꿈이 들어가 공개키가 두 줄이 됩니다.

### 1-4. 변수 파일

`terraform.tfvars.example`을 `terraform.tfvars`로 복사하고 값을 채웁니다. 이 파일은 git에서 제외됩니다.

- `aws_profile`: 1-2의 프로필 이름
- `expected_account_id`: 다른 계정 자격 증명이면 plan이 실패합니다.
- `allowed_cidrs`: 예 `["1.2.3.4/32"]`. 현재 공인 IP는 `https://checkip.amazonaws.com`에서 확인합니다. 서버가 이미 있으면 지금 규칙(`aws lightsail get-instance-port-states`)을 보고 맞춥니다.
- `budget_emails`

PowerShell 5.1에서 파일을 만들 때는 BOM 없는 UTF-8로 씁니다: `[IO.File]::WriteAllText(<경로>, <내용>, (New-Object Text.UTF8Encoding $false))`.

## 2. 인프라 적용

```powershell
terraform init
terraform plan -out=deploy.tfplan     # 생성·변경 목록과 계정 확인
terraform apply deploy.tfplan
terraform output                      # static_ip, url, ssh
```

- 만들어지는 것: SSH 키 등록, 인스턴스, 고정 IP와 연결, 방화벽(22·80을 허용 IP에만 개방), 월 예산 알림.
- plan에 교체(`-/+`)나 삭제가 있으면 apply하지 않습니다. 고정 IP를 다시 만들면 공인 주소가 바뀝니다.
- 첫 부팅 때 `user-data.sh`가 실행됩니다. Lightsail은 user_data를 `/bin/sh`로 실행하므로, sh 래퍼가 bash 스크립트(`/usr/local/sbin/workout-init`)를 써서 실행합니다. swap 2GB, Docker·Compose 설치, 앱 저장소 clone, DB 비밀번호 생성(서버 `.env`, 외부로 나가지 않음), 백업 cron, 자동 배포 timer를 설정합니다. 몇 분 걸립니다.
- `user_data`는 첫 부팅 때만 실행됩니다. 바꿔도 기존 인스턴스를 다시 만들지 않습니다(`ignore_changes`).

## 3. state 관리

- remote backend(S3 등)가 없습니다. state(`terraform.tfstate`)는 apply한 PC의 이 폴더에만 있고 git에서 제외됩니다.
- apply 뒤에는 state와 `terraform.tfvars`를 리포 밖에 백업합니다. OneDrive처럼 클라우드로 동기화되는 폴더는 피합니다.
  ```powershell
  $bak = "$HOME\Backups\terraform-$(Get-Date -Format yyyyMMdd)"
  New-Item -ItemType Directory -Force $bak | Out-Null
  Copy-Item terraform.tfstate*, terraform.tfvars $bak
  ```
- 다른 PC로 옮길 때는 백업한 파일을 새 PC의 이 폴더에 복사하고 `terraform init`, `terraform plan`으로 "No changes"를 확인합니다.
- provider 버전을 올리면 state가 새 형식으로 저장되어 되돌릴 수 없습니다. 버전 변경 PR을 먼저 병합한 뒤 apply합니다.

## 4. state를 잃었을 때 (import로 다시 만들기)

state 없이 plan하면 모든 리소스를 새로 만들려고 합니다. 그대로 apply하지 말고 기존 리소스를 import합니다.

### 4-1. 리소스 확인

```powershell
$p = "--profile","workout-personal"
aws lightsail get-instances @p --query "instances[].{name:name,state:state.name,key:sshKeyName}" --output table
aws lightsail get-static-ips @p --query "staticIps[].{name:name,attachedTo:attachedTo}" --output table
aws lightsail get-key-pairs @p --query "keyPairs[].name" --output table
aws lightsail get-instance-port-states @p --instance-name workout-memo-app --output table
```

### 4-2. import 가능 여부

| 리소스 | import | 처리 |
|---|---|---|
| `aws_lightsail_instance.app` | 가능(이름) | import |
| `aws_lightsail_static_ip.app` | 가능(이름, provider v6.8.0 이상) | import |
| `aws_lightsail_static_ip_attachment.app` | 가능(고정 IP 이름, v6.10.0 이상) | import |
| `aws_budgets_budget.monthly` | 가능(`계정ID:이름`) | import |
| `aws_lightsail_key_pair.deploy` | 불가 | 콘솔에서 기존 키 쌍을 지우고 apply로 새로 만듦 |
| `aws_lightsail_instance_public_ports.app` | 불가 | apply가 같은 규칙을 덮어씀 |
| `terraform_data.account_guard` | 해당 없음 | apply가 새로 만듦(AWS에는 만들지 않음) |

### 4-3. 절차

1. 커밋하지 않을 import 파일을 만들고, 이 clone에서만 git이 무시하게 합니다.
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
2. `terraform init`, `terraform plan -out=import.tfplan`. 기대 결과는 `4 to import, 3 to add, 0 to change, 0 to destroy`입니다. 다르면 apply하지 않습니다.
3. Lightsail 콘솔 → 계정 → SSH 키에서 서울 리전의 `workout-memo-deploy`를 삭제합니다. 실행 중인 인스턴스는 영향을 받지 않습니다.
4. `terraform apply import.tfplan` 뒤 `terraform plan`이 "No changes"인지 확인합니다.
5. `imports.local.tf`, `import.tfplan`을 지우고 3장대로 state를 백업합니다.
6. 새 SSH 키는 서버에 아직 없습니다. 5장으로 서버 `authorized_keys`에 추가합니다.

## 5. 새 PC의 SSH 키를 서버에 추가하기

기존 키로 접속할 수 있으면 그 PC에서 `authorized_keys`에 추가합니다. 기존 키를 잃었으면 Lightsail 브라우저 SSH를 잠깐 허용해서 추가합니다.

1. 콘솔 → 인스턴스 → Networking → SSH(22) 규칙 편집 → **Allow Lightsail browser SSH** 체크 → Save.
2. Connect 탭 → Connect using SSH에서 실행합니다(`>>` 두 개).
   ```bash
   echo '<새 공개키 한 줄>' >> ~/.ssh/authorized_keys
   tail -n 2 ~/.ssh/authorized_keys
   ```
3. 다시 SSH 규칙 편집 → **Allow Lightsail browser SSH** 체크 해제 → Save. 이 설정은 Terraform plan에 나오지 않으므로 직접 확인합니다.
   ```powershell
   aws lightsail get-instance-port-states --profile workout-personal --instance-name workout-memo-app --query "portStates[].{port:fromPort,aliases:join(',',cidrListAliases)}" --output table   # aliases가 비어 있어야 함
   ```
4. 처음 접속할 때 나오는 서버 지문을 AWS 값과 비교한 뒤 `yes`로 답합니다.
   ```powershell
   aws lightsail get-instance-access-details --profile workout-personal --instance-name workout-memo-app --protocol ssh --query "accessDetails.hostKeys[].{alg:algorithm,sha256:fingerprintSHA256}" --output table
   ssh -i "$HOME\.ssh\workout-memo-lightsail" ubuntu@<static_ip> "hostname; uptime"
   ```

## 6. 접속

- **브라우저**: `http://<static_ip>`. 허용 IP에서만 열립니다.
- **SSH**: `ssh -i ~/.ssh/workout-memo-lightsail ubuntu@<static_ip>`
- **SSH 터널**(전송 암호화): `ssh -i ~/.ssh/workout-memo-lightsail -L 8101:127.0.0.1:80 ubuntu@<static_ip>`를 실행한 뒤 `http://localhost:8101`로 접속합니다.

## 7. 허용 IP 바꾸기

`terraform.tfvars`의 `allowed_cidrs`에 추가·삭제한 뒤 plan과 apply를 실행합니다. 방화벽 규칙만 바뀌고 인스턴스는 그대로입니다. 전체 공개(`/0`)는 변수 검증에서 거부됩니다.

## 8. 알람(선택)

Terraform AWS provider에는 Lightsail 지표 알람 리소스가 없습니다. 필요하면 CLI로 만듭니다. 알람당 월 약 $0.10이며, 이메일 연락처는 AWS 확인 메일을 승인해야 동작합니다.

```powershell
aws lightsail create-contact-method --profile workout-personal --protocol Email --contact-endpoint <이메일>
aws lightsail put-alarm --profile workout-personal --alarm-name workout-memo-status --monitored-resource-name workout-memo-app --metric-name StatusCheckFailed --comparison-operator GreaterThanOrEqualToThreshold --threshold 1 --evaluation-periods 2 --notification-enabled --contact-protocols Email
```

## 9. 철거

`terraform destroy`를 실행하면 인스턴스·고정 IP·방화벽·예산이 삭제되고, 서버 안의 DB와 덤프도 함께 사라집니다. 필요한 백업을 먼저 PC로 가져옵니다(앱 리포 문서). 자동 스냅샷은 인스턴스 삭제 후에도 남아 비용이 나올 수 있으므로 Lightsail 콘솔에서 확인합니다.

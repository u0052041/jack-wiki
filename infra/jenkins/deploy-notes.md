---
layout: default
title: Terraform + Jenkins 學習筆記
parent: Infra / DevOps
nav_order: 4
---

# Terraform + Jenkins 學習筆記

## 專案結構

```
infra/
├── networking/          ← 共用網路層（VPC、subnet、NAT GW）
│   ├── provider.tf
│   ├── variables.tf
│   ├── locals.tf
│   ├── vpc.tf
│   └── outputs.tf
└── jenkins/
    ├── data.tf          ← 讀 networking remote state
    ├── provider.tf
    ├── variables.tf
    ├── locals.tf
    ├── acm.tf           ← ACM 憑證
    ├── alb.tf           ← ALB + Listener
    ├── sg.tf            ← ALB SG + Controller SG
    ├── iam.tf           ← IAM Role + SSM + EKS + ECR
    ├── ecr.tf           ← ECR repo + image build（buildx --platform linux/amd64）
    ├── Dockerfile       ← Custom Jenkins image（aws cli + kubectl + helm）
    ├── main.tf          ← EC2 + EBS + user_data + container update
    └── outputs.tf
```

## IaC 分層原則

```
networking/  → 管共用網路（VPC、subnet、NAT GW）
jenkins/     → 管 Jenkins infra（EC2、ALB、ACM、SG、IAM）
             → user_data 負責 EC2 上的軟體安裝（Docker、Jenkins）
```

EC2 軟體安裝用 `user_data`，只在開機時跑一次。升級 Jenkins image 手動進去操作：
```bash
aws ssm start-session --target $(terraform output -raw instance_id)
docker pull jenkins/jenkins:new-version
docker stop jenkins && docker rm jenkins
# 重新 docker run（參考 main.tf user_data）
```

## .gitignore

```
.terraform/
terraform.tfstate
terraform.tfstate.backup
```

`terraform.lock.hcl` **要進版控**（鎖定 provider 版本）

---

## Step 1：Networking 層

Jenkins 和未來其他服務（EKS、RDS）共用同一個 VPC。

```
VPC 10.0.0.0/16
├── public-1a   10.0.1.0/24   ← ALB、NAT GW
├── public-1c   10.0.2.0/24   ← ALB
├── private-1a  10.0.10.0/24  ← Jenkins EC2、EKS nodes（未來）
└── private-1c  10.0.11.0/24  ← EKS nodes（未來）
```

```bash
cd infra/networking
terraform init && terraform apply
```

### 開關 NAT Gateway（省錢）

```bash
terraform apply -var="enable_nat_gateway=false"  # 關（省 $32/月）
terraform apply -var="enable_nat_gateway=true"   # 開
```

> **注意**：Jenkins EC2 在 private subnet，`enable_nat_gateway=false` 時 EC2 無法對外，user_data 會失敗（dnf install、docker pull 都需要出口）。關 NAT Gateway 前確保 EC2 已經正常跑起來。

---

## Step 2：Remote State（data.tf）

Jenkins 透過 remote state 讀取 networking 的 output：

```hcl
data "terraform_remote_state" "networking" {
    backend = "local"
    config  = { path = "../networking/terraform.tfstate" }
}

# 使用
vpc_id     = data.terraform_remote_state.networking.outputs.vpc_id
subnet_ids = data.terraform_remote_state.networking.outputs.public_subnet_ids
```

---

## Step 3：ACM 憑證（acm.tf）

DNS 驗證，憑證免費。Apply 後需手動到 Cloudflare 加一筆 CNAME：

```bash
terraform output acm_validation_cname
# 把輸出的 name/value 加到 Cloudflare DNS
# Terraform 會等待驗證完成（aws_acm_certificate_validation）
```

憑證驗證完成後才會建立 HTTPS listener。

---

## Step 4：ALB（alb.tf）

internet-facing ALB，HTTP 自動 redirect 到 HTTPS：

```
Internet → ALB:80  → redirect 301 → ALB:443 → Jenkins EC2:8080
```

### 開關 ALB（省錢）

```bash
terraform apply -var="enable_alb=false"  # 關（省 $16/月）
terraform apply -var="enable_alb=true"   # 開
```

ALB 關掉（destroy）後重新建立，DNS name 會不同，需要到 Cloudflare 更新 CNAME。

---

## Step 5：Security Group（sg.tf）

| SG | 規則 |
|----|------|
| `jenkins-alb-sg` | ingress 80/443 from 0.0.0.0/0 |
| `jenkins-controller-sg` | ingress 8080 from ALB SG（SG chaining）|

SG chaining：不寫死 IP，用 SG ID 當來源，IP 變動不影響規則。

```hcl
resource "aws_security_group_rule" "controller_from_alb" {
    source_security_group_id = aws_security_group.alb[0].id  # 來源是 ALB SG
    security_group_id        = aws_security_group.jenkins_controller.id
}
```

---

## Step 6：EC2 + EBS（main.tf）

```
aws_instance          → Jenkins Controller（user_data 自動裝 Docker + Jenkins）
aws_ebs_volume        → 20GB gp3（Jenkins 資料持久化）
aws_volume_attachment → 掛載到 EC2（/dev/xvdf 或 /dev/nvme1n1）
```

EBS 有 `prevent_destroy = true`，`terraform destroy` EC2 不會刪掉資料。

user_data 啟動流程：
1. 安裝 Docker
2. 等待 EBS 裝置出現（最多等 150 秒）
3. 格式化 EBS（首次）並掛載到 `/mnt/jenkins-data`
4. 登入 ECR，拉取 custom Jenkins image
5. 啟動 Jenkins container（使用 ECR image）

---

## Step 7：ECR + Custom Jenkins Image（ecr.tf + Dockerfile）

### Dockerfile

在 `jenkins/jenkins:2.541.3-lts` 基礎上加裝 CI/CD 工具：

```
FROM jenkins/jenkins:2.541.3-lts
├── AWS CLI      ← Terraform、SSM、ECR 操作
├── kubectl      ← 操作 EKS 叢集
└── Helm         ← 部署 K8s 應用
```

### ECR 資源

```
aws_ecr_repository        → 存放 custom Jenkins image
aws_ecr_lifecycle_policy  → 只保留最近 5 個 image
null_resource             → Dockerfile 變動時自動 build + push
```

### Cross-Platform Build

Jenkins EC2 是 `x86_64`，本機 Mac 是 `arm64`，build 時必須指定平台：

```bash
docker buildx build --platform linux/amd64 -t <ecr_url>:latest .
```

不加 `--platform` 會 push arm64 image，EC2 pull 時報錯：
```
no matching manifest for linux/amd64 in the manifest list entries
```

### Image 更新機制（null_resource）

Dockerfile 改動 → Terraform 偵測 `filemd5()` 變化 → 觸發兩個 `null_resource`：

```
1. jenkins_image_build      → 本機 buildx + push 到 ECR
2. jenkins_container_update → SSM 送指令到 EC2：pull + restart container
```

強制測試整個流程（不改 Dockerfile）：
```bash
terraform apply \
    -replace=null_resource.jenkins_image_build \
    -replace=null_resource.jenkins_container_update
```

`filemd5()` 的上次數值存在 `terraform.tfstate` 的 triggers 裡，每次 plan/apply 時跟當前值比較。

---

## Step 8：IAM（iam.tf）

| Resource | 用途 |
|----------|------|
| `aws_iam_role` (jenkins) | EC2 掛的 role |
| `AmazonSSMManagedInstanceCore` | SSM Session Manager（不需要 SSH）|
| `jenkins-eks-policy` | SSM Parameter 讀取 + EKS DescribeCluster |
| `AmazonEC2ContainerRegistryReadOnly` | 從 ECR 拉 Jenkins image |
| `aws_iam_instance_profile` | EC2 與 IAM Role 的橋樑 |

EC2 不能直接掛 Role，需透過 `instance_profile`。

---

## Step 9：Outputs（outputs.tf）

```bash
terraform output                    # 查所有
terraform output -raw instance_id   # 查單一（-raw 不含引號）
```

| Output | 用途 |
|--------|------|
| `instance_id` | SSM 連入、CLI 操作用 |
| `ssm_command` | 直接複製貼上連入 EC2 |
| `alb_dns_name` | 在 Cloudflare 加 CNAME 指向這個 |
| `acm_validation_cname` | 在 Cloudflare 加這筆 CNAME 驗證憑證 |

---

## Step 10：部署流程

```bash
# 1. 建 networking
cd infra/networking
terraform init && terraform apply

# 2. 建 Jenkins（首次 apply 會 build + push ECR image）
cd infra/jenkins
terraform init && terraform apply

# 3. 驗證 ACM 憑證
terraform output acm_validation_cname
# → 到 Cloudflare 加 CNAME，等待 Terraform 完成驗證

# 4. 設定 domain
terraform output alb_dns_name
# → 到 Cloudflare 加 CNAME：jenkins.yourdomain.com → ALB DNS

# 5. 等 EC2 user_data 跑完（約 2-3 分鐘）
# 用 SSM 連入確認
aws ssm start-session --target $(terraform output -raw instance_id)
docker ps  # 確認 jenkins container 在跑

# 6. 拿初始密碼
aws ssm start-session --target $(terraform output -raw instance_id)
docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
```

Jenkins 初始設定：
1. `https://jenkins.yourdomain.com`
2. 貼初始密碼
3. Install suggested plugins
4. 建立管理員帳號

### 常用操作

```bash
# 強制重建 EC2（user_data 會重跑，但 EBS 資料保留）
terraform apply -replace=aws_instance.jenkins

# 更新 Jenkins image（改 Dockerfile 後）
terraform apply
# → 自動 buildx --platform linux/amd64 → push ECR → SSM restart container

# 強制重新 build + deploy（不改 Dockerfile）
terraform apply \
    -replace=null_resource.jenkins_image_build \
    -replace=null_resource.jenkins_container_update
```

---

## Terraform 常用語法

### count

決定要建幾個 resource，`count = 0` 等同於不建：

```hcl
count = var.enable_nat_gateway ? 1 : 0
```

- `count` 建出來的 resource 是 list，引用時要加 index：`aws_eip.nat[0].id`
- `count = 0` 時完全不建，比 `destroy` 範圍小，只刪這個 resource

### depends_on

明確指定建立順序，**只在 Terraform 無法自動偵測依賴時才需要寫**：

```hcl
resource "aws_nat_gateway" "main" {
    depends_on = [aws_internet_gateway.main]  # 先建 IGW，再建 NAT GW
}
```

Terraform 透過引用關係自動判斷順序（例如 `allocation_id = aws_eip.nat[0].id` 會自動等 EIP 建好）。
但 NAT GW 和 IGW 之間沒有直接引用，Terraform 無法自動判斷，需要手動寫 `depends_on`。

### locals vs variables

| | `variables.tf` | `locals.tf` |
|--|----------------|-------------|
| 可從外部傳入 | ✅（`-var="key=value"`）| ❌ |
| 可做運算/組合 | ❌ | ✅ |
| 適合放 | 使用者可能想改的值 | 內部衍生的計算值 |

---

## Terraform 常用指令

| 指令 | 用途 |
|------|------|
| `terraform init` | 初始化，下載 provider |
| `terraform plan` | 預覽變更 |
| `terraform apply` | 套用變更 |
| `terraform destroy` | 刪除所有資源 |
| `terraform apply -replace=<resource>` | 強制重建特定 resource |
| `terraform state list` | 列出管理中的資源 |
| `terraform state rm <resource>` | 從 state 移除 resource（不刪除實際資源）|
| `terraform fmt` | 格式化 .tf 檔案 |
| `terraform validate` | 驗證語法 |
| `terraform output` | 查看所有 output |
| `terraform output -raw <key>` | 查單一 output（不含引號）|

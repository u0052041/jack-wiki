# Terraform + Jenkins 學習筆記

## 專案結構

```
infra/jenkins/
├── provider.tf      # AWS provider 設定
├── vpc.tf           # VPC、Subnet、IGW、Route Table
├── sg.tf            # Security Group
├── iam.tf           # IAM Role、Policy、Instance Profile
├── main.tf          # Key Pair、EC2、EIP、EBS
├── ecs.tf           # ECS Cluster + Task Definition（Jenkins Agent）
├── cloudwatch.tf    # CloudWatch Log Group
├── variables.tf     # 變數定義
├── locals.tf        # 共用 tag
├── outputs.tf       # 輸出值
└── ansible/         # EC2 software 安裝（待建）
```

## IaC 分層原則

```
Terraform → 管 infra（VPC、SG、EC2、EBS、IAM、ECS）
Ansible   → 管 EC2 上的 software（Docker、Jenkins、cloudflared）
```

EC2 上的軟體不寫在 `user_data`，改由 Ansible 管理。原因：
- `user_data` 只在開機時跑一次，失敗不易 debug
- Ansible 可重複執行（idempotent）、可讀性高、易維護

## .gitignore

```
.terraform/              # provider plugin，terraform init 會重新產生
terraform.tfstate        # 包含敏感資訊，不進版控
terraform.tfstate.backup
```

`terraform.lock.hcl` **要進版控**（鎖定 provider 版本）

---

## Step 1：Provider（provider.tf）

```bash
terraform init   # 每個新專案第一次執行，下載 provider plugin
```

---

## Step 2：VPC（vpc.tf）

### 架構
```
VPC (10.0.0.0/16)
└── Subnet (10.0.1.0/24) — ap-northeast-1a
      └── Route Table → Internet Gateway（對外流量）
```

### 資源說明

| Resource | 用途 |
|----------|------|
| `aws_vpc` | 定義私有網段 |
| `aws_subnet` | VPC 內的子網路 |
| `aws_internet_gateway` | 讓 EC2 可連外網 |
| `aws_route_table` | 定義流量走向（0.0.0.0/0 → IGW）|
| `aws_route_table_association` | 把 Route Table 綁到 Subnet |

---

## Step 3：Security Group（sg.tf）

兩個 SG：`jenkins_controller`（EC2 用）、`jenkins_agent`（Fargate 用）

### Controller SG 規則

| 方向 | Port | 用途 | 來源 |
|------|------|------|------|
| ingress | 22 | SSH（Ansible 連入）| 0.0.0.0/0 |
| ingress | 50000 | Agent 連入 | jenkins_agent SG |
| egress | 0 | 所有對外流量 | 0.0.0.0/0 |

> 8080 不對外開放。cloudflared 從 EC2 內部連 `localhost:8080`，再透過 Tunnel 讓外部用戶走 `https://jenkins.yourdomain.com`。

### Agent SG 規則

| 方向 | Port | 用途 |
|------|------|------|
| egress | 0 | 所有對外流量（連 Controller + 拉 image）|

### SG 互相引用（循環依賴解法）

Fargate IP 是動態的，無法用 CIDR 限制來源，改用 SG 互相引用。
但兩個 SG 直接互相引用會造成 Terraform 循環依賴，解法是用 `aws_security_group_rule` 把規則獨立出來：

```hcl
# 在 controller SG 上開洞，來源是 agent SG
resource "aws_security_group_rule" "controller_from_agent" {
  type                     = "ingress"
  security_group_id        = aws_security_group.jenkins_controller.id
  source_security_group_id = aws_security_group.jenkins_agent.id
}
```

- `security_group_id` — 這條規則屬於哪個 SG
- `source_security_group_id` — 來源是哪個 SG（只用於 ingress）
- egress 只用 `security_group_id` + `cidr_blocks`，不用 `source_security_group_id`

---

## Step 4：IAM（iam.tf）

| Resource | 用途 |
|----------|------|
| `aws_iam_role` (jenkins) | EC2 用，允許操作 ECS |
| `aws_iam_role_policy` (jenkins_ecs) | ECS 操作權限，Resource 限縮到 Cluster ARN |
| `aws_iam_role_policy_attachment` (jenkins_ssm) | 附加 SSM Session Manager（SSH 備援）|
| `aws_iam_instance_profile` | EC2 與 IAM Role 的橋樑 |
| `aws_iam_role` (ecs_task_execution) | Fargate 啟動 container 用 |
| `aws_iam_role_policy_attachment` (ecs_task_execution) | 附加 `AmazonECSTaskExecutionRolePolicy` |

- EC2 不能直接掛 Role，需透過 `instance_profile`
- `iam:PassRole` — Jenkins 需要這個權限來啟動 ECS Task
- ECS Task Execution Role 的 Principal 是 `ecs-tasks.amazonaws.com`
- `aws_iam_role_policy_attachment` vs `aws_iam_role_policy`：前者附加 AWS managed policy，後者自訂

---

## Step 5：EBS Volume 持久化（main.tf）

讓 Jenkins 資料在 EC2 重建後仍然保留。

| Resource | 用途 |
|----------|------|
| `aws_ebs_volume` | 獨立磁碟（20GB, gp3, 加密）|
| `aws_volume_attachment` | 掛載到 EC2（`/dev/xvdf`）|

EBS 是獨立 resource，`terraform destroy` EC2 不會連帶刪除，資料安全。
實際格式化與掛載由 Ansible 處理。

---

## Step 6：EC2 + Key Pair（main.tf）

```
aws_key_pair  → SSH 公鑰上傳 AWS（~/.ssh/jenkins-key.pub）
aws_instance  → EC2（Jenkins Controller）
aws_eip       → 固定公網 IP（EC2 重建後 IP 不變）
```

- Key pair 用 `file(var.ssh_public_key_path)` 讀本機公鑰，私鑰永遠不離開本機
- Jenkins image 版本鎖定在 `variables.tf`，由 Ansible 決定何時更新
- 查 Jenkins 版本：`docker exec jenkins java -jar /usr/share/jenkins/jenkins.war --version`

---

## Step 7：ECS Cluster + Task Definition（ecs.tf）

Jenkins Agent 動態開關的平台，Cluster 本身免費，只有跑 Task 時才計費。

| Resource | 用途 |
|----------|------|
| `aws_ecs_cluster` | Agent 跑的平台 |
| `aws_ecs_task_definition` | 定義 Agent container 規格（模板）|
| `aws_cloudwatch_log_group` | Agent log 存放（cloudwatch.tf）|

- Task definition 是**模板**，Jenkins ECS plugin 在 RunTask 時動態注入 `JENKINS_URL`、`JENKINS_SECRET`、`JENKINS_AGENT_NAME`，不需要寫死在 Terraform
- `network_mode = "awsvpc"` — Fargate 固定用這個
- `execution_role_arn` — 引用 ECS Task Execution Role
- log 用 `awslogs` driver，`awslogs-group` 引用 cloudwatch resource 避免寫死
- Agent image 版本要對應 Controller

---

## Step 8：Outputs（outputs.tf）

```bash
terraform output             # 查所有
terraform output elastic_ip  # 查單一
```

| Output | 用途 |
|--------|------|
| `elastic_ip` | Ansible inventory 填這個 |
| `ssh_command` | 直接複製貼上 SSH 進去 |
| `instance_id` | AWS console / CLI 操作用 |
| `ecs_cluster_arn` | Jenkins ECS plugin 設定：Cluster ARN |
| `ecs_task_execution_role_arn` | Jenkins ECS plugin 設定：Task Execution Role ARN |
| `agent_security_group_id` | Jenkins ECS plugin 設定：Security Group |
| `agent_subnet_id` | Jenkins ECS plugin 設定：Subnets |

---

## Step 9：部署流程

```bash
# 1. Terraform 建 infra
terraform plan && terraform apply

# 2. 拿 SSH 連線指令
terraform output ssh_command

# 3. Ansible 安裝 software（待補）
ansible-playbook -i inventory ansible/site.yml

# 強制重建 EC2（terraform taint 已棄用，改用 -replace）
terraform apply -replace=aws_instance.jenkins

# SSH（EC2 重建後清除舊 host key）
ssh-keygen -R <Elastic IP>
ssh -i ~/.ssh/jenkins-key ec2-user@<Elastic IP>

# Jenkins 初始密碼（Ansible 完成後）
docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
```

Jenkins 初始設定：
1. `https://jenkins.yourdomain.com`（Cloudflare Tunnel 設好後）
2. 貼初始密碼
3. Install suggested plugins
4. 建立管理員帳號

---

## Terraform 常用指令

| 指令 | 用途 |
|------|------|
| `terraform init` | 初始化，下載 provider |
| `terraform plan` | 預覽變更 |
| `terraform apply` | 套用變更 |
| `terraform destroy` | 刪除所有資源 |
| `terraform apply -replace=<resource>` | 強制重建特定 resource（取代舊版 taint）|
| `terraform state list` | 列出管理中的資源 |
| `terraform state rm <resource>` | 從 state 移除 resource（不刪除實際資源）|
| `terraform fmt` | 格式化 .tf 檔案 |
| `terraform validate` | 驗證語法 |
| `terraform output` | 查看所有 output |

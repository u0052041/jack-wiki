---
layout: default
title: EKS 部署筆記
parent: Infra / DevOps
nav_order: 9
---

# EKS 部署筆記
{: .no_toc }

專案結構、部署決策、Jenkins 整合、ALB Controller Pipeline
{: .fs-6 .fw-300 }

## 目錄
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## 一、專案結構

```
infra/
├── networking/          ← 共用網路層（VPC、subnet、NAT GW）
│   └── outputs.tf       ← 輸出 vpc_id、private_subnet_ids 給其他模組用
├── jenkins/             ← Jenkins CI server
└── k8s/                 ← EKS 叢集
    ├── provider.tf      ← AWS provider + required_providers
    ├── variables.tf     ← cluster_name、node 規格等變數
    ├── locals.tf        ← common_tags
    ├── data.tf          ← remote state + Jenkins SG data source
    ├── eks.tf           ← EKS Cluster + OIDC Provider + Jenkins Access Entry
    ├── iam.tf           ← Cluster Role + Node Role + Policy Attachments
    ├── node-group.tf    ← Managed Node Group
    ├── sg.tf            ← Jenkins → EKS API 443 ingress rule
    ├── alb-controller.tf← ALB Controller IRSA + SSM Parameters
    ├── outputs.tf       ← cluster endpoint、CA cert、ALB Role ARN
    ├── policies/        ← ALB Controller IAM Policy JSON
    └── Jenkinsfile      ← CI pipeline：讀 SSM → helm install ALB Controller
```

網路層用 `terraform_remote_state` 共享，k8s 模組從 `../networking/terraform.tfstate` 讀 VPC 和 subnet。

---

## 二、Cluster 設定決策

### Private Endpoint Only

```hcl
vpc_config {
    subnet_ids              = data.terraform_remote_state.networking.outputs.private_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = false
}
```

Cluster API endpoint 完全不對外開放，只有 VPC 內部能呼叫：

```
你的筆電 ──✕──→ EKS API（不通）
Jenkins（同 VPC）──✓──→ EKS API（通）
```

好處是安全，壞處是本機 `kubectl` 不能直接用，必須透過 VPN 或 SSM 跳板。

### Access Config

```hcl
access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
}
```

`API_AND_CONFIG_MAP` 代表同時支援兩種 K8s 存取控制：
- **API 模式**：用 `aws_eks_access_entry` 在 Terraform 裡直接管理（新做法）
- **ConfigMap 模式**：傳統 `aws-auth` ConfigMap（向下相容）

`bootstrap_cluster_creator_admin_permissions = true` 讓建叢集的 IAM 身份自動拿到 admin 權限，不然連建完的人自己都進不去。

### Control Plane Logging

```hcl
enabled_cluster_log_types = ["api", "audit", "authenticator"]
```

Prod 環境至少開 `audit`（誰做了什麼）和 `authenticator`（debug IAM / IRSA 問題）。Log 會送到 CloudWatch Logs，注意 log 量大時會有費用。

---

## 三、Jenkins 與 EKS 整合

### 問題：Jenkins 怎麼操作 K8s？

Jenkins 跑在同一個 VPC 的另一台 EC2 上，要能：
1. 呼叫 EKS API（kubectl / helm）
2. 擁有 K8s 叢集內的操作權限

### 網路層：Security Group Rule

```hcl
resource "aws_security_group_rule" "eks_from_jenkins" {
    type                     = "ingress"
    from_port                = 443
    to_port                  = 443
    protocol                 = "tcp"
    security_group_id        = eks_cluster_sg     # EKS 的 SG
    source_security_group_id = jenkins_sg         # Jenkins 的 SG
}
```

EKS API 跑在 443，這條規則讓 Jenkins SG 的流量能進到 EKS SG。

### 權限層：EKS Access Entry

```hcl
resource "aws_eks_access_entry" "jenkins" {
    cluster_name  = "main-eks"
    principal_arn = "arn:aws:iam::xxx:role/jenkins-role"
    type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "jenkins" {
    policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy"
    access_scope { type = "cluster" }
}
```

這是 EKS 新的權限管理方式（取代 `aws-auth` ConfigMap）：
- `access_entry` — 聲明「jenkins-role 可以存取這個叢集」
- `access_policy_association` — 給予 `Admin` 權限，scope 是整個叢集

```
Jenkins EC2 → assume jenkins-role → 呼叫 EKS API
                                     ↓
                        EKS 查 Access Entry：
                        "jenkins-role 有 Admin，放行"
```

### 資料傳遞：SSM Parameters

Terraform 建完 EKS 後，Jenkins Pipeline 需要知道一些值（Role ARN、VPC ID 等）。

做法是 Terraform 把值寫進 SSM Parameter Store，Jenkinsfile 再讀出來：

```
Terraform 寫入：
  /eks/main-eks/alb-controller-role-arn  → IAM Role ARN
  /eks/main-eks/cluster-name             → main-eks
  /eks/main-eks/aws-region               → ap-northeast-1
  /eks/main-eks/vpc-id                   → vpc-xxx

Jenkinsfile 讀取：
  aws ssm get-parameter --name /eks/main-eks/alb-controller-role-arn
```

為什麼不直接 hardcode？因為 Role ARN 包含 AWS Account ID 和亂數，每次 `terraform apply` 都可能不同。用 SSM 當中間層，Pipeline 不需要改就能適應變化。

---

## 四、Jenkinsfile — ALB Controller 部署 Pipeline

```
Stage 1: Read SSM Parameters
  └─ 從 SSM 讀 ALB Role ARN 和 VPC ID

Stage 2: Configure kubectl
  └─ aws eks update-kubeconfig（讓 kubectl 能連到叢集）

Stage 3: Install ALB Controller
  └─ helm upgrade --install（冪等操作：沒有就裝，有就升級）

Stage 4: Verify
  └─ kubectl get deployment 確認 Controller 跑起來了
```

`helm upgrade --install` 是 Helm 的冪等用法 — 第一次跑等於 install，之後跑等於 upgrade。CI 可以重複跑不會壞。

### 為什麼用 Jenkinsfile 而不是 Terraform helm_release

本專案的 ALB Controller 是透過 **Jenkinsfile + helm CLI** 部署的，不是用 Terraform `helm_release`。

| | Jenkinsfile + helm CLI | Terraform helm_release |
|---|---|---|
| Helm state 管理 | Helm 自己管（存在 K8s Secret） | 存在 Terraform state |
| 部署觸發 | Jenkins Pipeline 手動/自動觸發 | `terraform apply` |
| 適合 | CI/CD 流程中部署，跟其他 K8s 部署統一 | 基礎設施層級元件，跟 IAM/OIDC 一起管 |

兩種做法都可以。目前選擇 Jenkinsfile 是因為 ALB Controller 的部署邏輯（讀 SSM → configure kubectl → helm install）適合放在 CI pipeline 裡跑。

---

## 五、部署流程

```bash
# 1. 建 networking（如果還沒建）
cd infra/networking
terraform init && terraform apply

# 2. 建 EKS 叢集
cd infra/k8s
terraform init && terraform apply
# → 建 EKS Cluster、Node Group、OIDC、IAM Roles、SSM Parameters

# 3. 在 Jenkins 跑 ALB Controller Pipeline
# → 讀 SSM → configure kubectl → helm install ALB Controller

# 4. 部署應用程式
# → 寫 Ingress YAML → ALB Controller 自動建 ALB
```

### Terraform 和 Helm 的分工

```
Terraform 管 AWS 側：
  1. OIDC Provider     ← IAM 服務
  2. IAM Role          ← IAM 服務
  3. IAM Policy        ← IAM 服務

Helm 管 K8s 側（透過 Jenkinsfile）：
  4. ServiceAccount    ← K8s 資源
  5. Controller Pod    ← K8s 資源
  6. RBAC 權限         ← K8s 資源
```

兩邊靠 SA annotation（`eks.amazonaws.com/role-arn`）串起來。

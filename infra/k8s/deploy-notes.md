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
├── networking/          ← 共用網路層（VPC、subnet、NAT GW、ACM wildcard cert）
│   ├── acm.tf           ← Wildcard ACM *.u0052041.com + SSM parameter
│   └── outputs.tf       ← 輸出 vpc_id、private_subnet_ids、wildcard_cert_arn
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
    ├── ingress.yaml               ← Ingress 規則（envsubst 注入 cert ARN）
    ├── test-app.yaml              ← 測試用 Deployment + Service + PDB
    ├── policies/                  ← ALB Controller IAM Policy JSON
    ├── Jenkinsfile.alb-controller ← 安裝/升級 ALB Controller
    └── Jenkinsfile.ingress        ← 部署/更新 Ingress 規則
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

## 四、Jenkinsfile.alb-controller — ALB Controller 部署 Pipeline

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

### 完整順序

```bash
# 1. 建 networking（含 wildcard ACM cert）
cd infra/networking
terraform init && terraform apply
# 首次需到 Cloudflare 加 CNAME 驗證：terraform output acm_validation_cname

# 2. 建 EKS 叢集
cd infra/k8s
terraform init && terraform apply

# 3. 在 Jenkins 跑 Jenkinsfile.alb-controller Pipeline（初次建叢集才需要）
# 讀 SSM → configure kubectl → helm install ALB Controller

# 4. 在 Jenkins 跑 Jenkinsfile.ingress Pipeline
# 讀 SSM cert ARN → deploy test-app + ingress

# 5. 設定 DNS
# Pipeline 的 Verify stage 會印出 ALB DNS name
# 到 Cloudflare 加 CNAME：app.u0052041.com → ALB DNS name
```

### ACM cert ARN 注入方式

ingress.yaml 裡的 `certificate-arn` 用 `${WILDCARD_CERT_ARN}` 佔位符，部署時透過 `sed` 注入實際值（Jenkins container 沒有 `envsubst`，用 `sed` 替代）。

cert ARN 存在 SSM Parameter `/shared/wildcard-cert-arn`，跟 ALB Controller 的 SSM pattern 一致（`/eks/main-eks/*`）。這樣做的原因：
- cert ARN 包含 AWS Account ID，不適合 hardcode 在 YAML 裡
- Jenkins Pipeline 可以直接從 SSM 讀取，不需要傳參數
- 跟現有 ALB Controller 的 SSM 慣例統一

### Ingress 設計決策

**Ingress Group**：所有服務共用同一個 ALB（`group.name: main`），用 host-based routing 分流。這樣做是因為每個 ALB 約 $16/月，共用一個可以省成本，未來加服務只需要新增 ingress rule。

**HTTPS**：ALB 同時監聽 HTTP:80 和 HTTPS:443，HTTP 自動 301 redirect 到 HTTPS。cert 使用 networking 層的 wildcard `*.u0052041.com`。

**TLS Policy**：使用 `ELBSecurityPolicy-TLS13-1-2-2021-06`，只允許 TLS 1.2 和 1.3，符合 prod security baseline。

**Target Type**：使用 `ip` 模式（而非 `instance`），ALB 直接連到 Pod IP，不經過 NodePort，延遲更低。

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

---

## 六、Jenkins Kubernetes Agent

### 為什麼要把 Agent 放到 K8s Pod？

現有 Jenkinsfile 用 `agent any`，代表所有 job 直接跑在 Jenkins Master container 裡。問題：

- 資源互搶：多個 job 同時跑，Master CPU/RAM 是共用的
- 無法隔離：job 之間可能互相影響
- 擴展困難：Master 是單機，無法水平擴展

改成 K8s agent 後，每個 job 動態建立獨立 Pod，跑完自動刪除。

### 工作原理（WebSocket 模式）

```
Jenkins Master（EC2）
  │ 1. 偵測到 agent { kubernetes {...} }
  │ 2. 呼叫 EKS API :443 → 建立 agent Pod
  ▼
EKS：Pod 啟動（jnlp + aws-tools containers）
  │ 3. jnlp container 透過 WebSocket 連回 Jenkins
  ▼    https://jenkins.u0052041.com → Cloudflare → ALB → Master
Jenkins 接受連線 → stages 在 Pod 內執行 → Pod 完成後刪除
```

WebSocket 模式讓 agent 透過 HTTPS 443 連回 Master，不需要額外開放 TCP 50000 port。這是 cloud-native 環境（EKS + ALB + CDN）的主流做法。

傳統 JNLP 模式需要：
```
Agent Pod → Master :50000（直接 TCP）
```
在 ALB + Cloudflare 架構下走不通（ALB 沒有 50000 listener）。

### Agent Pod 通常跑什麼

本專案的 agent pod 只負責 **deploy 任務**，不涉及 Docker：

| 任務 | 命令 |
|------|------|
| 取得 kubeconfig | `aws eks update-kubeconfig` |
| 讀取設定值 | `aws ssm get-parameter` |
| 更新 deployment | `kubectl set image` / `helm upgrade` |
| 等待 rollout | `kubectl rollout status` |

### IRSA for Agent Pod

Agent pod 裡的 `aws-cli` 需要呼叫 AWS API（讀 SSM、describe EKS），透過 IRSA 取得權限，模式與 ALB Controller 完全相同：

```
Terraform 管 AWS 側：
  1. IAM Role（assume policy 綁定 OIDC + ServiceAccount）
  2. IAM Policy（SSM read + EKS describe）
  3. SSM Parameter 存 Role ARN

K8s 側（YAML）：
  4. Namespace: jenkins-agents
  5. ServiceAccount: jenkins-agent（annotation: role-arn）
  6. ClusterRole + ClusterRoleBinding（kubectl 操作權限）
```

與 ALB Controller IRSA 的差異：
- ALB Controller 需要操作 AWS 資源（建 ALB、改 SG）→ 權限範圍廣
- Jenkins Agent 只需要讀 SSM + describe EKS → 最小權限

### Jenkinsfile 改法

把 `agent any` 換成 `agent { kubernetes { yaml "..." } }`，Pod template 包含兩個 container：
- `jnlp`：負責 WebSocket 連回 Master（固定寫法，用官方 `jenkins/inbound-agent` image）
- `aws-tools`：重用現有 Jenkins ECR image（已含 kubectl/helm/aws-cli），實際跑 deploy 命令

### Jenkins UI 設定步驟

**Step 1：安裝 Kubernetes Plugin**
`Manage Jenkins → Plugins → Available` → 搜尋 `kubernetes` → 安裝

**Step 2：啟用 WebSocket**
`Manage Jenkins → Security → Agent protocols` → 勾選 **WebSocket**

**Step 3：設定 Kubernetes Cloud**
`Manage Jenkins → Clouds → New Cloud → Kubernetes`：

| 欄位 | 值 | 說明 |
|------|-----|------|
| Kubernetes URL | （空白） | Plugin 自動用 Master 的 kubeconfig |
| Jenkins URL | `https://jenkins.u0052041.com` | Agent Pod 連回 Master 的地址 |
| Jenkins tunnel | （空白） | WebSocket 不需要 |
| Namespace | `jenkins-agents` | Agent Pod 建在此 namespace |
| Use WebSocket | 勾選 | 透過 HTTPS 連回，不用 50000 port |

### agent any vs agent kubernetes

| | `agent any` | `agent kubernetes` |
|---|---|---|
| 執行位置 | Jenkins Master container | EKS 動態 Pod |
| 資源隔離 | 無 | 有（每 job 獨立） |
| 執行完清理 | 無 | 自動刪 Pod |
| 設定複雜度 | 零 | 需要 K8s Plugin + RBAC |
| 適合 | 低頻、infra 操作 | 高頻、需要隔離的 job |

建議：`Jenkinsfile.alb-controller` 這類低頻 infra pipeline 保留 `agent any` 即可；日後新增服務 deploy pipeline 再用 `agent kubernetes`。

### 初次部署順序

```bash
# 1. 建 IRSA Role
cd infra/k8s && terraform apply
```

```
# 2. 在 Jenkins 跑 Jenkinsfile.jenkins-agent
#    讀 SSM → apply namespace + RBAC → annotate SA → verify
```

```
# 3. Jenkins UI 設定（見上方步驟）
```

### 相關檔案

- `infra/k8s/jenkins-agent-namespace.yaml` — namespace 定義
- `infra/k8s/jenkins-agent-rbac.yaml` — SA + ClusterRole + Binding
- `infra/k8s/jenkins-agent-irsa.tf` — IRSA + SSM Parameter
- `infra/k8s/Jenkinsfile.jenkins-agent` — K8s 資源初始化 Pipeline

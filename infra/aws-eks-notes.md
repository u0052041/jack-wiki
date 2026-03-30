---
layout: default
title: EKS 筆記
parent: Infra / DevOps
nav_order: 8
---

# EKS 筆記
{: .no_toc }

EKS 叢集架構、IAM Roles、Node Group、Jenkins 整合、IRSA、ALB Controller、Helm
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

## 二、EKS Cluster 設定

### Private Endpoint Only

```hcl
vpc_config {
    subnet_ids              = data.terraform_remote_state.networking.outputs.private_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = false
}
```

Cluster API endpoint 完全不對外開放，只有 VPC 內部能呼叫。這代表：

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

---

## 三、IAM Roles — Cluster 和 Node 各需一個

### EKS Cluster Role

EKS 服務本身需要一個 IAM Role 才能運作（管 control plane、發 K8s API）：

```hcl
assume_role_policy → Principal: eks.amazonaws.com
attached policy    → AmazonEKSClusterPolicy
```

這是 AWS 管的 control plane 在用，不是你的 Pod 在用。

### EKS Node Role

Worker Node（EC2）需要另一個 Role，掛了四個 AWS managed policy：

| Policy | 用途 |
|--------|------|
| `AmazonEKSWorkerNodePolicy` | 讓 Node 跟 EKS control plane 通訊 |
| `AmazonEKS_CNI_Policy` | VPC CNI plugin — 幫 Pod 分配 VPC 內的 IP |
| `AmazonEC2ContainerRegistryReadOnly` | 從 ECR 拉 container image |
| `AmazonSSMManagedInstanceCore` | 讓 SSM Session Manager 能連進 Node（除錯用） |

```
Cluster Role → EKS 服務本身用
Node Role    → EC2 worker node 用
ALB Role     → ALB Controller Pod 用（透過 IRSA）
```

三個 Role 各司其職，不要搞混。

---

## 四、Node Group

```hcl
resource "aws_eks_node_group" "main" {
    instance_types  = ["t3.medium"]
    subnet_ids      = private_subnet_ids

    scaling_config {
        desired_size = 2
        min_size     = 2
        max_size     = 2
    }

    update_config {
        max_unavailable = 1    # 滾動更新時最多一台不可用
    }
}
```

用 **Managed Node Group**，AWS 幫你管 Node 的生命週期（AMI 更新、drain、替換）。

`max_unavailable = 1` 代表更新 Node 時一次只下線一台，確保服務不中斷。

Node 跑在 private subnet，沒有 public IP，對外流量走 NAT Gateway。

---

## 五、Jenkins 與 EKS 整合

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
    policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
    access_scope { type = "cluster" }
}
```

這是 EKS 新的權限管理方式（取代 `aws-auth` ConfigMap）：
- `access_entry` — 聲明「jenkins-role 可以存取這個叢集」
- `access_policy_association` — 給予 `ClusterAdmin` 權限，scope 是整個叢集

```
Jenkins EC2 → assume jenkins-role → 呼叫 EKS API
                                     ↓
                        EKS 查 Access Entry：
                        "jenkins-role 有 ClusterAdmin，放行"
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

## 六、Jenkinsfile — ALB Controller 部署 Pipeline

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

---

## 七、為什麼需要 ALB Controller

EKS 叢集跑在 private subnet，外部流量進不來。需要一個東西在 public subnet「接客」，那就是 ALB。

但 K8s 和 AWS 是兩個世界：

```
K8s 的世界：Pod、Service、Ingress
AWS 的世界：ALB、Target Group、Listener Rule
```

Pod 不知道什麼是 Target Group，ALB 也不知道什麼是 Pod。**ALB Controller 就是翻譯**：

```
你寫一個 Ingress YAML
       ↓
ALB Controller 看到了（它跑在叢集裡）
       ↓
翻譯成 AWS 資源：建 ALB + Target Group + Listener Rule
       ↓
Pod IP 註冊到 Target Group，Pod 重建換 IP 時自動更新
```

沒有它，你就要自己手動維護「哪些 Pod IP 在哪個 Target Group 裡」，Pod 每次重啟 IP 都會變，根本管不動。

---

## 八、ServiceAccount — Pod 在 K8s 裡的身份

K8s 裡每個 Pod 都有一個身份，叫 ServiceAccount（SA）。

```
Pod 啟動時：
"我是 kube-system namespace 裡的 aws-load-balancer-controller"
```

就像你進公司有工牌，上面寫你是誰、哪個部門的。但這張工牌**只在公司內部有用**（K8s 內部）。

問題：ALB Controller 需要呼叫 **AWS API** 來建 ALB，而 AWS 不認 K8s 工牌，AWS 只認 IAM Role。

---

## 九、OIDC Provider — 讓 AWS 信任 K8s 的橋樑

OIDC Provider 是在 **AWS IAM** 裡面註冊的 Identity Provider（不是 Policy，不是 Role）。

```
AWS IAM
├── Users              （人類帳號）
├── Roles              （角色，可以被 assume）
├── Policies           （權限規則：能做什麼）
└── Identity Providers  ← OIDC Provider 在這裡
```

它的作用是讓 AWS 信任 EKS 發出的 token：

```
沒有 OIDC：
  Pod: "我是 aws-load-balancer-controller，我要建 ALB"
  AWS: "你誰？不認識，滾"

有了 OIDC：
  Pod: "我是 aws-load-balancer-controller，這是我的 K8s token"
  AWS: "讓我問一下 EKS 的 OIDC... 確認了，你是本人"
  AWS: "好，給你 IAM Role 的臨時憑證，去做吧"
```

### OIDC Provider 的設定

OIDC Provider 本身**不設權限**，只需要三個欄位：

```hcl
resource "aws_iam_openid_connect_provider" "eks" {
    # 1. EKS 叢集的 OIDC URL（每個叢集一個，不分 AZ）
    url             = aws_eks_cluster.main.identity[0].oidc[0].issuer

    # 2. 誰來換憑證（固定值，AWS 規定的）
    client_id_list  = ["sts.amazonaws.com"]

    # 3. 驗證 URL 是真的 EKS，不是假冒的（TLS 憑證指紋）
    thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
}
```

設完就結束，它就只是一個「信任聲明」。

---

## 十、IRSA — 讓 K8s SA 能用 IAM Role

IRSA（IAM Roles for Service Accounts）不是一個 AWS 服務，而是一個**模式**，由以下元件組合：

```
OIDC Provider          ← 建立信任
IAM Role + Condition   ← 指定哪個 SA 能用
SA annotation          ← 在 K8s 側綁定 Role
```

### IAM 裡的兩種 Policy

```
assume_role_policy  → 門禁：誰能進來（誰能 assume 這個 Role）
iam_policy          → 權限：進來之後能做什麼
```

**`assume_role_policy`** — 寫在 Role 裡面，決定「誰能用這個 Role」：

```hcl
assume_role_policy = jsonencode({
    Statement = [{
        Effect = "Allow"
        Principal = {
            Federated = aws_iam_openid_connect_provider.eks.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
            StringEquals = {
                # 只有這個 SA 能 assume 這個 Role
                "${oidc_issuer}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
            }
        }
    }]
})
```

**`aws_iam_policy`** — 獨立資源，定義「能做什麼」，再用 attachment 綁到 Role：

```hcl
resource "aws_iam_policy" "alb_controller" {
    policy = file("policies/alb-controller-policy.json")
    # 能建 ALB、改 Target Group、讀 EC2...（AWS 官方提供的 250 行 policy）
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
    role       = aws_iam_role.alb_controller.name
    policy_arn = aws_iam_policy.alb_controller.arn
}
```

分開寫是因為 `iam_policy` 可以被多個 Role 共用。`assume_role_policy` 則是每個 Role 各自不同，直接寫在 Role 裡。

### 為什麼 IRSA 是業界標準

| 做法 | 問題 |
|------|------|
| 把 AWS Access Key 塞進 Pod 環境變數 | 密鑰外洩風險，還要自己 rotate |
| 把 IAM Role 掛在 Node（EC2 instance profile） | 該節點上所有 Pod 都拿到同樣權限，沒辦法細分 |
| **IRSA** | 每個 Pod 各自綁定最小權限的 IAM Role，臨時憑證自動換發 |

---

## 十一、Helm — K8s 的套件管理 + 部署工具

### Helm 是什麼

類似 pip 但做更多事。pip 只下載套件，Helm 下載的是一整包 K8s 資源的模板（叫 **Chart**），然後幫你客製化並部署。

| 工具 | 做什麼 |
|------|--------|
| pip | 下載 Python 套件 |
| Helm | 下載 + 客製化 + 部署一整組 K8s 資源 |

更像 **docker-compose** 的角色 — 不只裝東西，是把一整套服務跑起來。

### Chart 裡面有什麼

```
aws-load-balancer-controller chart 裡面打包了：
├── Deployment          （跑 Controller Pod）
├── ServiceAccount      （Pod 的身份）
├── ClusterRole         （K8s 內部權限）
├── ClusterRoleBinding  （綁定權限）
├── Service             （內部通訊）
└── ...其他十幾個 YAML
```

如果沒有 Helm，你就要自己手寫這十幾個 YAML 然後 `kubectl apply`。

### 常用 Helm 指令

```bash
# 搜尋 chart
helm search repo aws-load-balancer-controller

# 安裝（手動）
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=main-eks \
  --set serviceAccount.create=true

# 查看已安裝的 release
helm list -n kube-system

# 升級
helm upgrade aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system --set clusterName=main-eks

# 解除安裝
helm uninstall aws-load-balancer-controller -n kube-system

# 查看 chart 的所有可設定值
helm show values eks/aws-load-balancer-controller
```

### 用 Terraform 管理 Helm

不用手動跑 `helm install`，直接在 Terraform 裡用 `helm_release` 資源：

```hcl
resource "helm_release" "alb_controller" {
    name       = "aws-load-balancer-controller"
    repository = "https://aws.github.io/eks-charts"
    chart      = "aws-load-balancer-controller"
    version    = "1.12.0"
    namespace  = "kube-system"

    # Helm 幫你在 K8s 裡建 SA
    set { name = "serviceAccount.create"; value = "true" }

    # SA 的名字
    set { name = "serviceAccount.name"; value = "aws-load-balancer-controller" }

    # SA 綁定哪個 IAM Role（IRSA 的關鍵）
    set {
        name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
        value = aws_iam_role.alb_controller.arn
    }
}
```

好處：版本鎖定、跟其他基礎設施一起管理、`terraform destroy` 時一起清掉。

那個 annotation 就是 IRSA 的接口 — Pod 啟動時 EKS 看到它，自動注入 AWS 臨時憑證。

### Terraform 和 Helm 的分工

```
Terraform 管 AWS 側：
  1. OIDC Provider     ← IAM 服務
  2. IAM Role          ← IAM 服務
  3. IAM Policy        ← IAM 服務

Helm 管 K8s 側：
  4. ServiceAccount    ← K8s 資源
  5. Controller Pod    ← K8s 資源
  6. RBAC 權限         ← K8s 資源
```

兩邊靠 SA annotation（`eks.amazonaws.com/role-arn`）串起來。

---

## 十二、完整流程

```
1. OIDC Provider    = AWS 跟 EKS 握手，建立信任
2. IAM Role + IRSA  = 這張 K8s 工牌可以換這張 AWS 通行證
3. Helm 裝 Controller = Pod 跑起來，拿工牌換通行證，開始幫你建 ALB
4. 你寫 Ingress YAML = Controller 自動在 public subnet 建 ALB
```

部署完成後，寫一個 Ingress 就能讓流量進來：

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
spec:
  rules:
    - host: app.example.com
      http:
        paths:
          - path: /
            backend:
              service:
                name: my-app
                port:
                  number: 80
```

Controller 看到這個 Ingress，就會自動在 public subnet 建一個 ALB，把流量導到 private subnet 的 Pod。

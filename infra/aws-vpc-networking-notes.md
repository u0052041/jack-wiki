---
layout: default
title: AWS VPC Networking
parent: Infra / DevOps
nav_order: 7
---

# AWS VPC Networking
{: .no_toc }

從 VPC 設計到 prod 環境網路架構的完整參考
{: .fs-6 .fw-300 }

## 目錄
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## 一、VPC 基礎概念

VPC（Virtual Private Cloud）是你在 AWS 上的**隔離網路空間**，所有資源都跑在 VPC 裡面。

```
Region
└── VPC（CIDR: 10.0.0.0/16）
    ├── Availability Zone A
    │   ├── Public Subnet  (10.0.1.0/24)
    │   └── Private Subnet (10.0.2.0/24)
    └── Availability Zone B
        ├── Public Subnet  (10.0.3.0/24)
        └── Private Subnet (10.0.4.0/24)
```

**Subnet 是 AZ 層級的**，一個 subnet 只屬於一個 AZ，這是 HA 設計的基礎——資源要跨 AZ 就要有多個 subnet。

---

## 二、CIDR 規劃

### 基本概念

CIDR 決定這個網段有幾個 IP，`/` 後面的數字越大，IP 數越少：

| CIDR | 固定位數 | 可變部分 | IP 數量 | 常見用途 |
|------|---------|---------|---------|---------|
| `/16` | 前兩段固定 | 後兩段可變（`x.x`）| 256 × 256 = 65,536 | VPC 本身 |
| `/24` | 前三段固定 | 最末段可變（`x`）| 256 | 一般 subnet |
| `/28` | 前三段半固定 | 最末 4 bits | 16 | 小型 subnet（如 ALB only）|
| `/32` | 全部固定 | 無 | 1 | 單一 IP（SG 白名單用）|

```
10.0.0.0/16  → 10.0.x.x        → 65,536 個 IP
10.0.1.0/24  → 10.0.1.x        → 256 個 IP
10.0.1.5/32  → 10.0.1.5 only   → 1 個 IP
```

AWS 每個 subnet 會保留 5 個 IP（前 4 + 最後 1），`/24` 實際可用 251 個。

### 規劃原則

```
VPC: 10.0.0.0/16

AZ-A:
  Public  10.0.1.0/24   (web / ALB)
  Private 10.0.2.0/24   (app server)
  Data    10.0.3.0/24   (RDS / ElastiCache)

AZ-B:
  Public  10.0.4.0/24
  Private 10.0.5.0/24
  Data    10.0.6.0/24
```

**常見錯誤：**
- VPC CIDR 切太小（之後要擴充很麻煩，VPC 無法縮小 CIDR）
- Subnet 切太滿，沒留空間給未來新服務
- 多個 VPC 之間 CIDR 重疊，導致之後 Peering 無法建立

> Prod 建議：VPC 用 `/16`，subnet 用 `/24`，不同環境（dev/staging/prod）用不同 VPC，CIDR 不要重疊。

---

## 三、對外連線：IGW / NAT Gateway / VPC Endpoint

### 三種路徑

```
有 Public IP  ──→ IGW ──→ Internet
沒有 Public IP ──→ NAT Gateway（放 public subnet）──→ IGW ──→ Internet
只連 AWS 服務  ──→ VPC Endpoint（不出 AWS 網路）
```

| | IGW | NAT Gateway | VPC Endpoint |
|---|---|---|---|
| 位置 | VPC 層級 | Public subnet | VPC 內部 |
| 方向 | **雙向**（進出都走它）| **單向**（只出不進）| 雙向 |
| 費用 | 免費 | 按時 + 流量計費 | Gateway 免費，Interface 按時計費 |
| 用途 | Public subnet 對外 | Private subnet 對外 | 存取 AWS 服務 |

> **IGW vs NAT GW 方向差異**：IGW 雙向，外部可主動連進來（配合 SG 控管）。NAT GW 單向，private subnet 可以出去，但外部無法主動連進來，這是 private subnet 的安全保障。

### Route Table 只管 Outbound

Route Table 只決定「封包要出去時走哪條路」，進來的流量靠 **connection tracking**（SG stateful）自動放行回程。

```
進來：Internet → IGW → local route 找到目標 subnet → SG 決定能不能進
出去：資源 → 查 Route Table → 走對應的出口（IGW / NAT GW）
回程：SG 是 stateful 的，允許進來的流量，回應自動放行，不靠 Route Table
```

AWS 內部仍會檢查 route table 確認 subnet 可達，但因為 `local` route（`10.0.0.0/16 → local`）永遠存在，VPC 內部路由一定通。重點是 **return traffic 靠 connection tracking（SG stateful），不是靠你設的 route table 規則**。

### Route Table 必要設定

```
Public subnet route table:
  10.0.0.0/16  → local
  0.0.0.0/0    → IGW

Private subnet route table:
  10.0.0.0/16  → local
  0.0.0.0/0    → NAT Gateway
```

### NAT Gateway vs NAT Instance

| | NAT Gateway | NAT Instance |
|---|---|---|
| 管理 | AWS 全管 | 自己維護 EC2 |
| HA | 每個 AZ 各建一個 | 要自己設定 failover |
| 費用 | 較高（按時 + 流量）| 較低（EC2 費用）|
| 效能 | 自動擴展 | 受 EC2 instance type 限制 |

> Prod 建議：用 NAT Gateway，**每個 AZ 各建一個**，避免跨 AZ 流量費用，也避免單點故障。

---

## 四、VPC Endpoint

### 兩種類型

#### Gateway Endpoint
- 只支援 **S3** 和 **DynamoDB**
- 免費
- 設定在 Route Table 上

```
Private subnet route table:
  10.0.0.0/16     → local
  0.0.0.0/0       → NAT Gateway
  s3 prefix list  → vpce-xxxxxxxx   ← S3 流量走 VPC Endpoint，不出 AWS
```

#### Interface Endpoint（AWS PrivateLink）
- 支援大多數 AWS 服務（SSM、Secrets Manager、ECR、SQS 等）
- 按時計費（約 $0.01/小時/AZ）
- 在 subnet 裡建一個 ENI，透過 private IP 連到 AWS 服務

```
Private EC2 ──→ Interface Endpoint ENI ──→ AWS Service
（不需要 NAT Gateway，流量不出 VPC）
```

### 什麼時候用 VPC Endpoint

- Private subnet 的 EC2 / Lambda 要存取 S3：用 Gateway Endpoint（免費）
- Private subnet 要呼叫 SSM / Secrets Manager：用 Interface Endpoint（不然要開 NAT GW 才能連）
- 安全要求高（不能讓流量走公網）：強制走 VPC Endpoint

---

## 五、多 VPC 連線

### VPC Peering

兩個 VPC 之間建立直連，流量走 AWS 內部網路。

```
VPC-A (10.0.0.0/16) ◀──── Peering ────▶ VPC-B (10.1.0.0/16)
```

**限制：**
- **不支援 transitive routing**：A-B、B-C 有 Peering，A 不能透過 B 連到 C，要再建 A-C Peering
- 兩個 VPC 的 CIDR **不能重疊**
- 要手動更新兩邊的 Route Table

```
VPC-A route table: 10.1.0.0/16 → pcx-xxxxxxxx
VPC-B route table: 10.0.0.0/16 → pcx-xxxxxxxx
```

### Transit Gateway

解決 Peering 的 transitive routing 問題，所有 VPC 連到 TGW，TGW 負責路由。

```
VPC-A ─┐
VPC-B ─┼─→ Transit Gateway ─→ 全部互通
VPC-C ─┘
```

| | VPC Peering | Transit Gateway |
|---|---|---|
| 架構 | 點對點 | Hub-and-spoke |
| Transitive routing | ❌ | ✅ |
| 管理複雜度 | VPC 多時很複雜 | 集中管理 |
| 費用 | 免費（同 region）| 按 attachment + 流量計費 |
| 適合 | 2-3 個 VPC 互連 | 多 VPC、多帳號環境 |

---

## 六、NACL vs Security Group

### 比較

| | NACL | Security Group |
|---|---|---|
| 作用層級 | Subnet | ENI（EC2 / RDS 等）|
| 狀態 | Stateless（來回都要設規則）| Stateful（回程自動允許）|
| 規則類型 | Allow + Deny | 只有 Allow |
| 評估順序 | 數字小的先，match 就停 | 所有規則一起評估 |
| 預設行為 | 預設 NACL 全放行 | 預設 SG 拒絕所有 inbound |

### SG 是 Stateful

SG 允許進來的流量，回去的回應自動允許，不需要另外設 outbound 規則：

```
Inbound: Allow TCP 443 from 0.0.0.0/0
→ 進來的 443 流量允許，回應自動放行，不需要設 outbound
```

### SG 只有 Allow，沒有 Deny

SG 只能寫允許規則，沒有匹配的預設全部拒絕。
想擋特定 IP 只能靠 NACL（有 Deny 規則）。

### SG 是綁在 ENI 上，不是 EC2

EC2 可以有多個網卡（ENI），每個 ENI 可以有不同 SG。
EKS node 的 Pod 網路也是透過 ENI 運作，理解這點在排查 EKS 網路問題時很重要。

### NACL Stateless 的影響

NACL 是 stateless，所以 inbound 和 outbound **都要設**：

```
允許外部 80 port 進來：
  Inbound:  Allow TCP 80 from 0.0.0.0/0
  Outbound: Allow TCP 1024-65535 to 0.0.0.0/0  ← ephemeral ports，回程用
```

### Security Group 最佳實踐

**Least Privilege（最小權限）：**
```
❌ 不好：Inbound 0.0.0.0/0 port 22
✅ 好：  Inbound 10.0.0.0/16 port 22（只開 VPC 內部）
✅ 更好：用 Session Manager，完全不開 22
```

**SG Chaining（用 SG ID 當來源，不用 IP）：**

```
ALB SG:     Inbound  443 from 0.0.0.0/0
App SG:     Inbound  8080 from ALB SG     ← 只允許來自 ALB 的流量
DB SG:      Inbound  5432 from App SG     ← 只允許來自 App server 的流量
```

這樣不管 IP 怎麼變，規則都自動適用，也更容易理解流量路徑。

---

## 七、Load Balancer 選型

### 三種 LB 比較

| | ALB | NLB | CLB |
|---|---|---|---|
| OSI 層 | Layer 7（HTTP/HTTPS）| Layer 4（TCP/UDP）| Layer 4/7（舊世代）|
| 路由依據 | path、header、host | IP + port | 基本 |
| 固定 IP | ❌（DNS 名稱）| ✅（Elastic IP）| ❌ |
| WebSocket | ✅ | ✅ | ❌ |
| gRPC | ✅（L7 routing）| ✅（TCP passthrough）| ❌ |
| 效能 | 好 | 極高、低延遲 | 差（不建議用）|
| 適合 | Web app、微服務 | 遊戲、IoT、需固定 IP | 舊系統遷移 |

### ALB 架構

```
Internet ──→ ALB
              ├── Listener: 80  → Redirect to 443
              └── Listener: 443 → Rules
                    ├── /api/*  → Target Group: API servers
                    ├── /static → Target Group: Static servers
                    └── default → Target Group: Web servers
```

**常用設定：**
- TLS 憑證掛在 ALB，後端 EC2 只跑 HTTP（termination at ALB）
- Sticky session 設在 Target Group（用 cookie 把同一個 user 導到同一台）
- Health check path 設成 `/health` 或 `/ping`

### NLB 使用場景

- 需要固定 IP（讓 client 設定防火牆白名單）
- 超低延遲（遊戲、金融）
- 非 HTTP 協定（TCP、UDP）
- 後端需要看到 client 真實 IP（ALB 會替換，NLB 不會）

---

## 八、Private EC2 連線方案

### Bastion Host（跳板機）

在 public subnet 放一台 EC2 作為跳板，SSH 進去再跳到 private subnet。

```
你的電腦 ──SSH──▶ Bastion（public subnet）──SSH──▶ Private EC2
```

**缺點：**
- 要管理 bastion 本身的安全性和 patch
- SSH key 管理麻煩
- 要開 port 22，有被暴力破解的風險

### AWS Session Manager（推薦）

透過 SSM Agent，**完全不需要 SSH、不需要開 port 22**。

```
你的電腦 ──▶ AWS Console / CLI ──▶ SSM Service ──▶ SSM Agent（EC2）
（走 HTTPS，不走 SSH，不需要 inbound rule）
```

**需要的條件：**
1. EC2 要有 SSM Agent（Amazon Linux 2 預設有）
2. EC2 的 IAM Role 要有 `AmazonSSMManagedInstanceCore` policy
3. 如果是 private subnet，要有 SSM 的 VPC Endpoint（或 NAT Gateway 讓 EC2 能連出去）

```bash
# 用 CLI 開 session
aws ssm start-session --target i-xxxxxxxxxxxxxxxxx

# Port forwarding（本地 3306 → 遠端 RDS 3306）
aws ssm start-session \
  --target i-xxxxxxxxxxxxxxxxx \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters '{"portNumber":["3306"],"localPortNumber":["3306"],"host":["mydb.xxxxx.rds.amazonaws.com"]}'
```

| | Bastion Host | Session Manager |
|---|---|---|
| 需要 port 22 | ✅ | ❌ |
| 需要 SSH key | ✅ | ❌ |
| 稽核 log | 要自己設 | 自動記錄到 CloudWatch / S3 |
| 費用 | EC2 費用 | 免費（SSM 本身免費）|
| 推薦 | 舊環境 | ✅ Prod 標準做法 |

---

## 九、典型 Prod 網路架構

```
Internet
    │
    ▼
Internet Gateway
    │
    ▼
┌─────────────────────────────────┐
│  Public Subnet (AZ-A / AZ-B)   │
│  - ALB                          │
│  - NAT Gateway                  │
└─────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────┐
│  Private Subnet (AZ-A / AZ-B)  │
│  - EC2 / ECS (App Server)       │
│  - SSM Agent（不開 22）         │
└─────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────┐
│  Data Subnet (AZ-A / AZ-B)     │
│  - RDS (Multi-AZ)               │
│  - ElastiCache                  │
└─────────────────────────────────┘
    │
    ▼
VPC Endpoints（S3, SSM, Secrets Manager）
```

**Security Group 流量路徑：**
```
Internet → ALB SG (443) → App SG (8080 from ALB SG) → DB SG (5432 from App SG)
```

---

## 十、常見觀念釐清

| 問題 | 答案 |
|------|------|
| Public subnet 和 Private subnet 差在哪？ | **Terraform 沒有 public/private 這個欄位，這是抽象概念**：Route Table 有 `0.0.0.0/0 → IGW` 就是 public，有 `0.0.0.0/0 → NAT GW` 就是 private，沒有對外路由就是 isolated |
| NAT Gateway 要放在哪個 subnet？ | Public subnet，Private subnet 的 route 指向它 |
| NACL 和 SG 哪個先評估？ | NACL 先（subnet 層），SG 後（instance 層）|
| ALB 後面的 EC2 需要 Public IP 嗎？ | 不需要，放 private subnet 就好，ALB 負責對外 |
| 跨 AZ 流量要錢嗎？ | 要，所以 NAT Gateway 每個 AZ 各建一個，避免跨 AZ |
| VPC Peering 可以 transitive 嗎？ | 不行，多 VPC 互連用 Transit Gateway |
| Session Manager 需要 NAT Gateway 嗎？ | 如果 private subnet 沒有 NAT GW，要建 SSM 的 VPC Endpoint |

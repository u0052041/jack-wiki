---
layout: default
title: ACM / ALB / Domain 完整串接流程
parent: Infra / DevOps
nav_order: 10
---

# ACM / ALB / Domain 完整串接流程
{: .no_toc }

從 ACM 驗證、ALB 掛證書到 Cloudflare DNS 指向，完整走一次 HTTPS 上線流程
{: .fs-6 .fw-300 }

## 目錄
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## 一、先搞懂三個角色

### ACM 做什麼

ACM（AWS Certificate Manager）負責：

- 申請 TLS 憑證
- 驗證你擁有該網域（DNS 驗證）
- 自動續期（前提是驗證用 DNS 記錄還在）

ACM 只負責「證書生命週期」，不負責接流量。

### ALB 做什麼

ALB（Application Load Balancer）負責：

- 接收使用者的 HTTP/HTTPS 請求
- 在 443 listener 使用 ACM 憑證做 TLS 終止
- 把流量轉給後端（例如 Jenkins EC2:8080）

### Domain（DNS）做什麼

DNS 負責把 `jenkins.yourdomain.com` 解析到 ALB 的 DNS 名稱。

簡單說：

```
ACM = 證書
ALB = 接流量 + 套用證書
DNS = 把人導到 ALB
```

---

## 二、CNAME 是什麼

CNAME 是 DNS 的「別名記錄」：把一個網域名稱指向另一個網域名稱。

### 你會遇到兩種 CNAME（最容易搞混）

| 類型 | 用途 | 例子 | 給誰看 |
|------|------|------|------|
| **驗證用 CNAME** | 證明你擁有網域，讓 ACM 發證書 | `_xxxx.jenkins.example.com -> _yyyy.acm-validations.aws` | ACM |
| **服務用 CNAME** | 讓使用者連到 ALB | `jenkins.example.com -> xxx.ap-northeast-1.elb.amazonaws.com` | 使用者 |

兩者都叫 CNAME，但用途完全不同。

---

## 三、完整流程（先看全貌）

```
1. Terraform 建 aws_acm_certificate（DNS 驗證）
2. terraform output acm_validation_cname
3. 到 Cloudflare 新增「驗證用 CNAME」
4. ACM 驗證通過，憑證狀態變 ISSUED
5. ALB 443 listener 綁定 certificate_arn
6. terraform output alb_dns_name
7. 到 Cloudflare 新增「服務用 CNAME」：
   jenkins.example.com -> <alb_dns_name>
8. 使用者開 https://jenkins.example.com
   DNS 解析到 ALB，ALB 用 ACM 憑證完成 TLS，再轉發到 Jenkins
```

---

## 四、一次走完整條鏈路（你專案可直接照跑）

### Step 1：先建立 Jenkins 基礎設施

```bash
cd infra/jenkins
terraform init
terraform apply
```

這一步會建立（或更新）：
- `aws_acm_certificate.jenkins`（憑證請求）
- `aws_lb.jenkins`、`aws_lb_listener.http`、`aws_lb_listener.https`（ALB 與 listener）
- `aws_instance.jenkins`（Jenkins EC2）

> 注意：`aws_acm_certificate_validation.jenkins` 會等待 DNS 驗證完成。如果還沒加驗證 CNAME，apply 可能卡在等待狀態。

### Step 2：取出 ACM 驗證用 CNAME，貼到 Cloudflare

```bash
terraform output acm_validation_cname
```

你會拿到一組 `name/type/value`。到 Cloudflare 新增 DNS 記錄：

```
Type: CNAME
Name: <output 裡的 name>
Target: <output 裡的 value>
```

這筆是給 ACM 驗證用，不是給使用者連網站用。

### Step 3：確認 ACM 憑證狀態變成 ISSUED

在 AWS Console 的 ACM 頁面確認該憑證狀態為 `ISSUED`。

狀態變成 `ISSUED` 後，ALB 的 443 listener 才能正確使用這張憑證。

### Step 4：取出 ALB DNS，貼服務用 CNAME

```bash
terraform output alb_dns_name
```

到 Cloudflare 新增：

```
Type: CNAME
Name: jenkins
Target: <alb_dns_name>
```

這筆才是給使用者流量走的 DNS 記錄。

### Step 5：開瀏覽器驗證最終路徑

打開 `https://jenkins.yourdomain.com`，預期路徑是：

```
瀏覽器
  -> Cloudflare DNS 查詢 jenkins.yourdomain.com
  -> 回傳 ALB DNS 名稱
  -> 連到 ALB:443
  -> ALB 用 ACM 憑證做 TLS 握手
  -> ALB 轉發到 Jenkins EC2:8080
```

---

## 五、這個專案的 Terraform 實作對照

### 1) `acm.tf`：申請與驗證憑證

- `aws_acm_certificate.jenkins`
  - `domain_name = var.jenkins_domain`
  - `validation_method = "DNS"`
- `aws_acm_certificate_validation.jenkins`
  - 會等待 DNS 驗證完成（設定 `create = "30m"`）

### 2) `alb.tf`：把憑證掛在 HTTPS listener

- `aws_lb_listener.https`
  - `port = 443`
  - `protocol = "HTTPS"`
  - `certificate_arn = aws_acm_certificate_validation.jenkins.certificate_arn`
- `aws_lb_listener.http`
  - `80 -> 443` 的 301 redirect

### 3) `outputs.tf`：輸出你要貼到 DNS 的值

- `acm_validation_cname`
  - 給 Cloudflare 加「驗證用 CNAME」
- `alb_dns_name`
  - 給 Cloudflare 加「服務用 CNAME」

---

## 六、Cloudflare 實作細節（避免踩坑）

### Step A：加 ACM 驗證 CNAME

```bash
cd infra/jenkins
terraform output acm_validation_cname
```

把輸出的 `name/type/value` 加到 Cloudflare DNS。

### Step B：確認憑證可用

在 ACM Console 確認憑證狀態為 `ISSUED`。

### Step C：加服務 CNAME 指向 ALB

```bash
terraform output alb_dns_name
```

在 Cloudflare 新增：

```
Type: CNAME
Name: jenkins
Target: <terraform output 的 alb_dns_name>
```

完成後，`https://jenkins.yourdomain.com` 應可連上。

---

## 七、上線前驗證清單

| 檢查項目 | 正常狀態 |
|------|------|
| ACM 憑證 | `ISSUED` |
| ALB Listener | 有 `HTTP:80` 與 `HTTPS:443` |
| HTTPS Listener 憑證 | 指向該 ACM 憑證 ARN |
| Cloudflare 驗證 CNAME | 存在（給 ACM） |
| Cloudflare 服務 CNAME | `jenkins -> alb_dns_name` |
| 瀏覽器 | 開 `https://jenkins...` 有鎖頭 |

---

## 八、常見錯誤與排查

### 錯誤 1：憑證一直 Pending validation

常見原因：
- 驗證用 CNAME 的 `name` 或 `value` 貼錯
- CNAME 尚未 DNS propagate
- 記錄被誤刪，導致續期失敗

### 錯誤 2：網域可連但不是 HTTPS 或證書不對

常見原因：
- ALB 只有 80 listener，沒有 443 listener
- 443 listener 沒綁對 `certificate_arn`
- DNS 指到錯誤 ALB

### 錯誤 3：ALB 重建後網站掛掉

常見原因：
- ALB DNS 變了，但 Cloudflare 服務用 CNAME 沒更新

---

## 九、常見觀念釐清

| 問題 | 答案 |
|------|------|
| ACM 驗證通過就代表網站 HTTPS 完成了嗎？ | 不一定。還要確保 ALB 的 443 listener 綁到該憑證，且 DNS 指到 ALB |
| 驗證用 CNAME 可以刪嗎？ | 不建議。刪掉會影響 ACM 自動續期 |
| 為什麼有兩筆 CNAME？ | 一筆給 ACM 驗證所有權，一筆給使用者把網域導到 ALB |
| ALB 後端 EC2 要自己裝憑證嗎？ | 不需要。這裡是 TLS terminate at ALB，後端可用 HTTP |
| Cloudflare 可以用 A 記錄直接指 ALB IP 嗎？ | 不行，ALB 沒固定 IP；應使用 CNAME 指到 ALB DNS 名稱 |

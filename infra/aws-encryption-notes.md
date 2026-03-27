---
layout: default
title: AWS 加密速查
parent: Infra / DevOps
nav_order: 6
---

# AWS 加密速查
{: .no_toc }

從加密基礎到 AWS 各服務的加密實務
{: .fs-6 .fw-300 }

## 目錄
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## 一、加密基礎

### 對稱 vs 非對稱

| | 對稱（AES） | 非對稱（RSA / ECC） |
|---|---|---|
| 金鑰 | 同一把 key 加解密 | 公鑰加密、私鑰解密 |
| 速度 | 快 | 慢 |
| 問題 | key 怎麼安全傳遞 | 解決 key 傳遞問題 |
| 場景 | 大量資料加密 | 金鑰交換、數位簽章 |

### 實務：兩者搭配使用

非對稱速度慢，不適合加密大量資料，實務上通常這樣配合：

```
1. 用非對稱（RSA）安全交換一把 AES Key
2. 之後用 AES Key 加密實際資料
```

TLS Handshake 就是這個模式的具體實現。

---

## 二、Envelope Encryption（AWS KMS 的核心）

### 概念

直接用 KMS 加密大量資料太慢（有大小限制，且每次都要走 API）。Envelope Encryption 的做法是：

```
資料  ──→  DEK 加密  ──→  加密資料（存 S3 / EBS 等）
DEK   ──→  KEK 加密  ──→  加密 DEK（和加密資料存在一起）
```

| 名詞 | 全名 | 說明 |
|------|------|------|
| DEK | Data Encryption Key | 實際用來加密資料的 key，每次產生新的 |
| KEK | Key Encryption Key | 加密 DEK 的 key，存在 KMS 裡不離開 |

### 解密流程

```
1. 把加密 DEK 送到 KMS
2. KMS 用 KEK 解密，回傳明文 DEK
3. 用明文 DEK 解密資料
4. 明文 DEK 用完就丟，不長期存在記憶體
```

**好處**：KMS 的 KEK 永遠不離開 AWS，就算加密資料被偷，沒有 KMS 存取權限也無法解密。

---

## 三、KMS 深入

### Key 類型

| 類型 | 說明 | 費用 |
|------|------|------|
| **AWS managed key** | AWS 自動為每個服務建立，如 `aws/s3`、`aws/ebs` | 免費 |
| **Customer managed key (CMK)** | 你自己建立，可自訂 key policy、rotation | $1/月/key |
| **AWS owned key** | AWS 內部使用，客戶看不到 | 免費 |

> Prod 建議：敏感資料用 CMK，才能精細控制誰可以用這把 key。

### Key Policy

KMS key 的存取控制是透過 **key policy**（不是 IAM policy），key policy 是 key 的主要存取控制。

```json
{
  "Statement": [
    {
      "Sid": "允許 root account 完整控制",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::123456789012:root" },
      "Action": "kms:*",
      "Resource": "*"
    },
    {
      "Sid": "允許特定 role 使用這把 key 加解密",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::123456789012:role/AppRole" },
      "Action": [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:GenerateDataKey"
      ],
      "Resource": "*"
    }
  ]
}
```

### 常用 KMS API

| API | 說明 |
|-----|------|
| `kms:Encrypt` | 加密資料（最大 4KB） |
| `kms:Decrypt` | 解密資料 |
| `kms:GenerateDataKey` | 產生 DEK（回傳明文 + 加密版本） |
| `kms:GenerateDataKeyWithoutPlaintext` | 只回傳加密版本的 DEK（延遲解密場景）|
| `kms:DescribeKey` | 查看 key 資訊 |

### Key Rotation（金鑰輪換）

```
啟用自動輪換 → 每年 AWS 自動產生新的 key material
舊資料：仍用舊 key material 解密（AWS 保留）
新資料：用新 key material 加密
```

- CMK 可開啟自動輪換（每 1 年，或設定 90-2560 天）
- AWS managed key 預設每年自動輪換
- **輪換後 key ID 不變**，應用程式不需要改設定

```bash
# 啟用自動輪換
aws kms enable-key-rotation --key-id <key-id>

# 查看輪換狀態
aws kms get-key-rotation-status --key-id <key-id>
```

### KMS Grants

Grant 是**臨時授權**，讓你在不改 key policy 的情況下，動態給某個 principal 使用 key 的權限。常用於 EC2 spot instance、Lambda 需要臨時存取 key 的場景。

```bash
# 建立 grant
aws kms create-grant \
  --key-id <key-id> \
  --grantee-principal arn:aws:iam::123456789012:role/TempRole \
  --operations Decrypt GenerateDataKey

# 撤銷 grant
aws kms retire-grant --key-id <key-id> --grant-id <grant-id>
```

---

## 四、At-Rest 加密

### S3

**Server-Side Encryption (SSE) 三種模式：**

| 模式 | 說明 | key 誰管 |
|------|------|---------|
| **SSE-S3** | AWS 管理 key，完全透明 | AWS |
| **SSE-KMS** | 用 KMS key，可審計誰解密過 | 你 + AWS |
| **SSE-C** | 你提供 key，每次請求都要帶 key | 你 |

> Prod 建議：SSE-KMS + CMK，可以在 CloudTrail 看到每次 Decrypt 的記錄。

```bash
# 設定 bucket 預設加密
aws s3api put-bucket-encryption \
  --bucket my-bucket \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "aws:kms",
        "KMSMasterKeyID": "arn:aws:kms:..."
      }
    }]
  }'
```

**S3 Bucket Policy 強制加密：**

```json
{
  "Effect": "Deny",
  "Principal": "*",
  "Action": "s3:PutObject",
  "Resource": "arn:aws:s3:::my-bucket/*",
  "Condition": {
    "StringNotEquals": {
      "s3:x-amz-server-side-encryption": "aws:kms"
    }
  }
}
```

### EBS

- 建立 volume 時勾選加密，或設定 account 層級預設加密
- 加密的 EBS snapshot → 複製出來的 volume 也是加密的
- 跨 region 複製 snapshot 可以換 key

```bash
# 設定 region 層級預設加密
aws ec2 enable-ebs-encryption-by-default
```

### RDS

- 建立 DB 時啟用加密（**建立後無法更改**）
- 若要加密現有 DB：建 snapshot → 複製 snapshot 並啟用加密 → 從加密 snapshot restore
- read replica 的加密狀態必須和 primary 一致

---

## 五、In-Transit 加密（TLS）

### TLS Handshake 流程

```
Client                              Server
  │──── ClientHello ──────────────▶ │  （支援的 cipher suites）
  │◀─── ServerHello + Certificate ──│  （選定 cipher，回傳憑證+公鑰）
  │  [驗證憑證：CA 簽名是否合法]      │
  │──── Pre-master secret ─────────▶│  （用 Server 公鑰加密）
  │  [雙方各自推導出相同的 Session Key]│
  │◀════════════ AES 加密通訊 ═══════│
```

### TLS 1.2 vs TLS 1.3

上面的 Handshake 流程描述的是 **TLS 1.2（RSA key exchange）**。TLS 1.3 是目前的標準（AWS ALB、CloudFront 預設支援），行為不同：

| | TLS 1.2 (RSA) | TLS 1.3 (ECDHE) |
|---|---|---|
| Key exchange | Client 產生 pre-master secret，用公鑰加密傳給 Server | 雙方各自產生 key share，共同推導 session key |
| Forward Secrecy | 選配 | 強制 |
| Handshake 來回 | 2-RTT | 1-RTT |

TLS 1.3 移除了 RSA key exchange，改用 **Ephemeral Diffie-Hellman（ECDHE）**，即使私鑰日後外洩，過去的流量也無法被解密（Forward Secrecy）。

### mTLS（雙向 TLS）

標準 TLS 只有 Client 驗 Server；mTLS **雙向驗證**，Server 也驗 Client 憑證。

```
適用場景：
- 微服務之間的互信（service mesh）
- API Gateway 對後端服務
- 零信任架構（Zero Trust）
```

---

## 六、ACM — AWS Certificate Manager

### 概念

ACM 幫你**免費申請、自動續期 TLS 憑證**，直接整合 ALB、CloudFront、API Gateway。

### 兩種憑證來源

| 來源 | 說明 |
|------|------|
| **ACM 申請（公開憑證）** | 免費，自動 renew，只能用在 AWS 服務（ALB、CF）|
| **Import 自有憑證** | 可用在任何地方，但 renew 要自己處理 |

### 驗證方式

申請憑證時要證明你擁有這個 domain：

| 方式 | 說明 | 推薦 |
|------|------|------|
| **DNS 驗證** | 在 Route 53 加一筆 CNAME record | ✅ 推薦，自動續期 |
| **Email 驗證** | 收驗證信點連結 | 不適合自動化 |

### 注意事項

- CloudFront 的憑證**必須在 us-east-1** 申請（全球服務的限制）
- ACM 憑證的私鑰 AWS 管理，你看不到，也無法 export（設計如此）
- 自動 renew 前提：DNS 驗證的 CNAME record 還在

---

## 七、Secrets Manager vs SSM Parameter Store

兩者都可以存 secret，但設計目的不同：

| | Secrets Manager | SSM Parameter Store |
|---|---|---|
| **費用** | $0.40/secret/月 | Standard 免費，Advanced $0.05/參數/月 |
| **自動 rotation** | ✅ 內建（RDS、Redshift、DocumentDB、自訂 Lambda）| ❌ 要自己實作 |
| **版本管理** | ✅ | ✅ |
| **加密** | 預設 KMS 加密 | Standard 明文，SecureString 才用 KMS |
| **跨帳號存取** | ✅ | 有限制 |
| **適合存什麼** | DB 密碼、API key（需要 rotation）| 設定值、非敏感參數、SSM 整合 |

### SSM Parameter Store 使用

```bash
# 存入加密參數
aws ssm put-parameter \
  --name "/prod/db/password" \
  --value "my-secret" \
  --type SecureString \
  --key-id alias/my-key

# 讀取（自動解密）
aws ssm get-parameter \
  --name "/prod/db/password" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text
```

### Secrets Manager 使用

```bash
# 存入 secret
aws secretsmanager create-secret \
  --name "prod/myapp/db" \
  --secret-string '{"username":"admin","password":"my-secret"}'

# 讀取
aws secretsmanager get-secret-value \
  --secret-id "prod/myapp/db" \
  --query "SecretString" \
  --output text
```

### Rotation（Secrets Manager）

```
啟用 rotation → 設定 rotation Lambda → 設定週期（如 30 天）
每次 rotation：Lambda 產生新密碼 → 更新 DB → 更新 Secrets Manager
```

應用程式每次都要重新 fetch secret，不能 cache 太久（否則 rotation 後連不上 DB）。

---

## 八、常見觀念釐清

| 問題 | 答案 |
|------|------|
| SSE-KMS 和 SSE-S3 差別？ | SSE-KMS 可以用 CloudTrail 審計每次解密，SSE-S3 不行 |
| KMS key 輪換後舊資料還能解密嗎？ | 可以，AWS 保留舊 key material，key ID 不變 |
| RDS 建立後可以開啟加密嗎？ | 不行，要透過 snapshot 複製的方式轉移 |
| ACM 憑證可以在 EC2 上用嗎？ | 不行，只能掛在 ALB / CloudFront / API Gateway |
| Secrets Manager 和 SSM 要選哪個？ | 需要自動 rotation 用 Secrets Manager，其他用 SSM 比較省錢 |
| mTLS 和 VPC 內部通訊要選哪個？ | 微服務互信用 mTLS，同 VPC 純隔離用 Security Group 就夠 |

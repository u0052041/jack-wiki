---
layout: default
title: Terraform 實戰筆記
parent: Infra / DevOps
nav_order: 11
---

# Terraform 實戰筆記
{: .no_toc }

從日常操作到 state 維護，整理一份可直接落地的 Terraform 工作手冊
{: .fs-6 .fw-300 }

## 目錄
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## 一、Terraform 基本循環

```bash
terraform init
terraform fmt -recursive
terraform validate
terraform plan
terraform apply
```

- `init`：初始化 provider / backend
- `fmt`：統一格式，避免 review noise
- `validate`：先擋語法與型別錯誤
- `plan`：先看 diff，再決定要不要 apply
- `apply`：真正改雲端資源

---

## 二、日常最常用指令（業界高頻）

| 指令 | 用途 |
|------|------|
| `terraform init -upgrade` | 升級 provider 到允許範圍的新版本 |
| `terraform plan -out=tfplan` | 產生可重播 plan 檔，避免 apply 前後不一致 |
| `terraform apply tfplan` | 套用同一份 plan（常見於 CI/CD） |
| `terraform apply -replace=<resource>` | 強制重建特定資源 |
| `terraform apply -refresh-only` | 只同步 state，不改基礎設施 |
| `terraform destroy` | 刪除資源（慎用） |
| `terraform output` / `-raw` | 查 outputs（給腳本用） |
| `terraform state list` | 列出 state 內資源 |
| `terraform state show <resource>` | 看某資源在 state 裡的值 |
| `terraform state rm <resource>` | 僅從 state 移除，不刪雲端資源 |
| `terraform import <addr> <id>` | 把既有資源納入 Terraform 管理 |
| `terraform providers lock` | 鎖定 provider checksum（跨平台一致） |

---

## 三、變數與環境管理

### `-var` / `-var-file`

```bash
terraform plan -var="enable_alb=false"
terraform plan -var-file="prod.tfvars"
```

- 單次切換用 `-var`
- 環境配置建議用 `*.tfvars`

### `TF_VAR_*`（CI 常用）

```bash
export TF_VAR_aws_region=ap-northeast-1
export TF_VAR_environment=prod
```

CI pipeline 常用環境變數注入機密或環境值，避免把敏感資訊寫在 repo。

---

## 四、Plan 檔工作流（推薦）

### 為什麼推薦

`plan` 到 `apply` 之間若程式或變數變了，直接 `terraform apply` 可能套到不同結果。  
用 plan 檔可確保「審核的是哪份，套用的就是哪份」。

### 流程

```bash
terraform plan -out=tfplan
terraform show tfplan
terraform apply tfplan
```

---

## 五、State 管理重點

State 是 Terraform 的真相來源，壞掉通常比程式碼錯誤更麻煩。

### 常見操作

```bash
terraform state list
terraform state show aws_instance.jenkins
terraform state rm aws_instance.legacy
terraform state mv aws_security_group.old aws_security_group.new
```

### 什麼時候用 `state rm`

- 雲端資源想保留，但不想再由 Terraform 管
- 誤 import 了錯誤資源

> `state rm` 不會刪實體資源，只是把它從 Terraform 管理清單移除。

---

## 六、`import` 與 `moved`（重構必學）

### import：接手既有資源

```bash
terraform import aws_s3_bucket.logs my-prod-logs-bucket
```

先把資源納入 state，再補齊對應 `.tf`，避免 drift。

### moved：重命名資源時保留 state

```hcl
moved {
  from = aws_security_group.old_name
  to   = aws_security_group.new_name
}
```

重構 resource name 時，用 `moved` 可避免 Terraform 誤判成「刪舊建新」。

---

## 七、`-target` 與 `depends_on` 的使用原則

### `-target`（救火工具，不是日常流程）

```bash
terraform apply -target=aws_instance.jenkins
```

- 優點：快速處理單點故障
- 風險：容易跳過整體依賴，造成後續不一致

建議：只在 emergency 使用，之後補一次完整 `plan/apply`。

### `depends_on`

僅在 Terraform 無法從引用關係推導依賴時才加，避免過度依賴造成無謂序列化。

---

## 八、與你這個專案最相關的範例

### 強制重建 Jenkins EC2（保留 EBS）

```bash
cd infra/jenkins
terraform apply -replace=aws_instance.jenkins
```

### 強制重跑 image build + 容器更新

```bash
terraform apply \
  -replace=null_resource.jenkins_image_build \
  -replace=null_resource.jenkins_container_update
```

### NAT Gateway 開關（在 networking 模組）

```bash
cd infra/networking
terraform apply -var="enable_nat_gateway=false"
terraform apply -var="enable_nat_gateway=true"
```

---

## 九、CI/CD 常見實務

### 建議流程

```bash
terraform fmt -check -recursive
terraform init -input=false
terraform validate
terraform plan -out=tfplan -input=false
# 人工審核或 PR comment
terraform apply -input=false tfplan
```

### 常見策略

- PR 只做 `plan`，不做 `apply`
- `apply` 僅允許在受保護分支與手動批准後執行
- 用 OIDC 或短期憑證，不在 CI 儲存長期 AWS key

---

## 十、Backend 與鎖定（Production 重點）

你目前 repo 內有 local state，學習很方便；但 production 建議：

- Backend 使用 S3
- 鎖定使用 DynamoDB（避免多人同時 apply）
- 開啟 state bucket 版本控管與加密

最小目標是避免「多人同時改 infra」導致 state 損壞。

---

## 十一、常見錯誤與排查

### 1) `Error acquiring the state lock`

- 有人正在 apply
- 上次流程異常中斷未釋放鎖

先確認是否真的無人在跑，再考慮 `force-unlock`。

### 2) `Value for undeclared variable`

- 在命令行傳了 root module 沒定義的變數
- 例：在 `infra/jenkins` 傳 `enable_nat_gateway`

### 3) `No changes` 但你覺得應該有變化

- 先檢查是否真的修改了 Terraform 追蹤的欄位
- 再看是否需要 `-replace`（例如 `null_resource` 觸發條件）

---

## 十二、速記：安全操作清單

每次動手前先做：

1. `terraform fmt -recursive`
2. `terraform validate`
3. `terraform plan`
4. 確認沒有非預期 destroy
5. 再 `terraform apply`

多人協作再加：

6. 遠端 backend + state lock
7. `plan` 與 `apply` 分離
8. 使用短期憑證與最小權限 IAM role

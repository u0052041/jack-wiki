---
layout: default
title: MySQL 線上不停機拆表實戰
parent: 系統設計
nav_order: 4
---

# MySQL 線上不停機拆表實戰：從單表到核心表 + 次要表
{: .no_toc }

Production 環境零停機、零掉資料的垂直拆分完整指南
{: .fs-6 .fw-300 }

## 目錄
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## 一、為什麼要拆表？

### 問題場景

```sql
-- 一張「什麼都塞」的訂單表，已經跑在線上
CREATE TABLE orders (
    id            BIGINT PRIMARY KEY AUTO_INCREMENT,
    user_id       BIGINT NOT NULL,
    status        TINYINT NOT NULL,          -- 核心：訂單狀態
    total_amount  DECIMAL(10,2) NOT NULL,    -- 核心：金額
    currency      VARCHAR(3) NOT NULL,       -- 核心
    created_at    DATETIME NOT NULL,         -- 核心

    -- 以下欄位 90% 的查詢用不到，但每次 SELECT * 都要讀
    shipping_name    VARCHAR(100),
    shipping_phone   VARCHAR(20),
    shipping_address TEXT,                   -- 次要：收件資訊
    invoice_title    VARCHAR(200),
    invoice_tax_id   VARCHAR(50),            -- 次要：發票資訊
    notes            TEXT,                   -- 次要：備註
    metadata         JSON,                   -- 次要：擴充欄位
    updated_at       DATETIME
);
```

### 拆分的收益

```
拆分前：
┌───────────────────────────────────────────────────┐
│ orders (單行 ≈ 2KB)                                │
│ 核心欄位 + 次要欄位全部混在一起                      │
│ → 熱查詢（列表頁、狀態查詢）每次都載入大量無用欄位   │
│ → Buffer Pool 被次要資料佔滿，快取命中率低          │
│ → 單行越大，一頁放的行數越少，I/O 次數越多          │
└───────────────────────────────────────────────────┘

拆分後：
┌──────────────────────┐  ┌──────────────────────────┐
│ orders (核心表)       │  │ order_details (次要表)     │
│ 單行 ≈ 100B          │  │ 單行 ≈ 1.9KB              │
│ id, user_id, status, │  │ order_id (FK), shipping,  │
│ total_amount,        │  │ invoice, notes, metadata  │
│ currency, created_at │  │                           │
│                      │  │                           │
│ → 一頁塞更多行       │  │ → 只有詳情頁才查           │
│ → Buffer Pool 效率高 │  │ → 不影響核心查詢效能       │
└──────────────────────┘  └──────────────────────────┘
```

| 收益 | 說明 |
|:-----|:-----|
| **Buffer Pool 命中率提升** | 核心表行更小，一頁放更多行，熱資料更容易留在記憶體 |
| **查詢效能提升** | 列表頁只讀核心表，I/O 減少 |
| **維護彈性** | 次要表可以獨立做 ALTER、加索引，不影響核心表 |
| **備份靈活** | 核心表高頻備份，次要表低頻備份 |

---

## 二、整體策略：Expand and Contract 模式

> **重點**：線上拆表的核心原則 — **永遠是先加再減、先寫再讀、先新再舊**。每一步都要可回滾，任何一步失敗都能退回上一步。
{: .note }

```
總共 6 個階段，每個階段之間都可以暫停和回滾：

Phase 1        Phase 2        Phase 3        Phase 4        Phase 5        Phase 6
建立新表  →  雙寫部署   →  回填歷史資料 →  資料驗證   →  切讀到新表  →  清理舊欄位
(Expand)     (Dual Write)  (Backfill)    (Verify)     (Switch Read)  (Contract)

風險：低        風險：中        風險：中        風險：無        風險：中        風險：高
可回滾：刪表    可回滾：關雙寫  可回滾：清新表  可回滾：N/A    可回滾：切回舊  可回滾：不做
```

```
時間軸：

  Day 1          Day 2-3        Day 3-5        Day 5-7        Day 7-14       Day 30+
  ┃              ┃              ┃              ┃              ┃              ┃
  建表           部署雙寫        跑回填腳本      驗證數據        Feature Flag    確認穩定
  ▼              ▼              ▼              ▼              切讀新表        刪舊欄位
                                                              ▼              ▼
```

> **重點**：不要趕，每個階段至少觀察 1-2 天。Phase 6（清理舊欄位）建議在切讀後至少觀察 2-4 週再執行。
{: .important }

---

## 三、Phase 1 — 建立新表

### 用 gh-ost 或 pt-online-schema-change

線上加表不影響服務，但如果後續需要對舊表加欄位（如加觸發器），建議用無鎖 DDL 工具：

```bash
# gh-ost: GitHub 開源的線上 DDL 工具，不用觸發器，基於 binlog
# pt-online-schema-change: Percona 工具，基於觸發器

# 建立次要表（這步純粹是新建表，直接 CREATE 即可）
```

```sql
-- 建立次要表
CREATE TABLE order_details (
    id         BIGINT PRIMARY KEY AUTO_INCREMENT,
    order_id   BIGINT NOT NULL,
    shipping_name    VARCHAR(100),
    shipping_phone   VARCHAR(20),
    shipping_address TEXT,
    invoice_title    VARCHAR(200),
    invoice_tax_id   VARCHAR(50),
    notes            TEXT,
    metadata         JSON,
    created_at       DATETIME NOT NULL,
    updated_at       DATETIME,

    UNIQUE KEY uk_order_id (order_id),  -- 一對一關係，用唯一索引
    KEY idx_created_at (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

**確認事項**：
- `order_id` 上有唯一索引（保證一對一）
- 字元集、排序規則與原表一致
- 不加外鍵約束（線上環境外鍵是效能殺手，關聯由應用層保證）

---

## 四、Phase 2 — 雙寫部署

### 核心原則：寫入時同時寫兩張表

```
雙寫期間的寫入流程：

  應用層 (Go)
     │
     ├── INSERT/UPDATE orders (核心表) ──→ 原本的寫入邏輯不變
     │
     └── INSERT/UPDATE order_details (次要表) ──→ 新增的寫入
            │
            失敗時：記錄到失敗佇列，不影響核心寫入
```

> **重點**：雙寫階段的鐵律 — **核心表寫入是主要操作，次要表寫入失敗不能影響核心流程**。次要表寫失敗就記 log + 放入重試佇列，不要讓它拖垮訂單建立。
{: .important }

### Go 實作 — Feature Flag + 雙寫

```go
// ① 定義拆分後的兩個 Model
type Order struct {
    ID          int64           `gorm:"primaryKey"`
    UserID      int64           `gorm:"not null"`
    Status      int8            `gorm:"not null"`
    TotalAmount float64         `gorm:"not null;type:decimal(10,2)"`
    Currency    string          `gorm:"not null;size:3"`
    CreatedAt   time.Time       `gorm:"not null"`
    // 過渡期：舊欄位先保留，不刪
    ShippingName    string      `gorm:"-"` // gorm 忽略，但程式中還在用
    ShippingPhone   string      `gorm:"-"`
    ShippingAddress string      `gorm:"-"`
}

type OrderDetail struct {
    ID              int64     `gorm:"primaryKey"`
    OrderID         int64     `gorm:"not null;uniqueIndex"`
    ShippingName    string    `gorm:"size:100"`
    ShippingPhone   string    `gorm:"size:20"`
    ShippingAddress string    `gorm:"type:text"`
    InvoiceTitle    string    `gorm:"size:200"`
    InvoiceTaxID    string    `gorm:"size:50"`
    Notes           string    `gorm:"type:text"`
    Metadata        JSON      `gorm:"type:json"`
    CreatedAt       time.Time `gorm:"not null"`
    UpdatedAt       time.Time
}
```

```go
// ② Feature Flag 控制雙寫開關
type SplitConfig struct {
    DualWriteEnabled bool  // Phase 2: 開啟雙寫
    ReadFromNew      bool  // Phase 5: 讀新表
    WriteOldDetail   bool  // Phase 6 前: 還寫舊表的次要欄位
}

// 從設定中心（etcd / Apollo / 環境變數）讀取，可動態切換
func GetSplitConfig() SplitConfig {
    return SplitConfig{
        DualWriteEnabled: featureFlag.GetBool("order_split.dual_write"),
        ReadFromNew:      featureFlag.GetBool("order_split.read_new"),
        WriteOldDetail:   featureFlag.GetBool("order_split.write_old_detail"),
    }
}
```

```go
// ③ 雙寫的建立訂單
func CreateOrder(ctx context.Context, db *gorm.DB, req *CreateOrderReq) (*Order, error) {
    cfg := GetSplitConfig()

    return db.Transaction(func(tx *gorm.DB) error {
        // 永遠先寫核心表（主要操作）
        order := &Order{
            UserID:      req.UserID,
            Status:      StatusCreated,
            TotalAmount: req.TotalAmount,
            Currency:    req.Currency,
            CreatedAt:   time.Now(),
        }

        // 過渡期：舊表的次要欄位也寫（直到 Phase 6 才停）
        if cfg.WriteOldDetail {
            tx.Exec(`INSERT INTO orders (...所有欄位...) VALUES (...)`, ...)
        } else {
            if err := tx.Create(order).Error; err != nil {
                return err
            }
        }

        // 雙寫次要表
        if cfg.DualWriteEnabled {
            detail := &OrderDetail{
                OrderID:         order.ID,
                ShippingName:    req.ShippingName,
                ShippingPhone:   req.ShippingPhone,
                ShippingAddress: req.ShippingAddress,
                InvoiceTitle:    req.InvoiceTitle,
                InvoiceTaxID:    req.InvoiceTaxID,
                Notes:           req.Notes,
                Metadata:        req.Metadata,
                CreatedAt:       order.CreatedAt,
            }
            if err := tx.Create(detail).Error; err != nil {
                // 次要表失敗 → 記 log + 丟重試佇列，不影響主交易
                log.Error("dual write order_details failed",
                    "order_id", order.ID, "error", err)
                PublishRetry(ctx, "order_detail_sync", detail)
                // 不 return err — 允許核心交易成功
            }
        }

        return nil
    })
}
```

```go
// ④ 雙寫的更新邏輯（同理）
func UpdateOrderShipping(ctx context.Context, db *gorm.DB, orderID int64, req *UpdateShippingReq) error {
    cfg := GetSplitConfig()

    // 更新舊表（過渡期保留）
    if cfg.WriteOldDetail {
        db.Model(&Order{}).Where("id = ?", orderID).Updates(map[string]interface{}{
            "shipping_name":    req.ShippingName,
            "shipping_phone":   req.ShippingPhone,
            "shipping_address": req.ShippingAddress,
        })
    }

    // 更新新表
    if cfg.DualWriteEnabled {
        result := db.Model(&OrderDetail{}).
            Where("order_id = ?", orderID).
            Updates(map[string]interface{}{
                "shipping_name":    req.ShippingName,
                "shipping_phone":   req.ShippingPhone,
                "shipping_address": req.ShippingAddress,
                "updated_at":      time.Now(),
            })

        if result.RowsAffected == 0 {
            // 歷史資料還沒回填，先 INSERT
            db.Create(&OrderDetail{
                OrderID:         orderID,
                ShippingName:    req.ShippingName,
                ShippingPhone:   req.ShippingPhone,
                ShippingAddress: req.ShippingAddress,
                CreatedAt:       time.Now(),
            })
        }
    }

    return nil
}
```

### 雙寫的一致性保證

```
Q: 如果核心表寫成功、次要表寫失敗怎麼辦？

A: 三道防線：
  ┌─────────────────────────────────────────────────┐
  │ 1. 同一個 DB Transaction                         │
  │    → 核心表和次要表在同一個 DB，用 TX 包           │
  │    → 次要表失敗可選擇記 log 而不 rollback         │
  ├─────────────────────────────────────────────────┤
  │ 2. 失敗重試佇列                                  │
  │    → 次要表失敗的記錄丟進 MQ / Redis              │
  │    → 背景 Worker 定期重試                        │
  ├─────────────────────────────────────────────────┤
  │ 3. 資料驗證 Job (Phase 4)                        │
  │    → 定期比對兩表，補齊遺漏                       │
  │    → 作為最終的安全網                             │
  └─────────────────────────────────────────────────┘
```

---

## 五、Phase 3 — 回填歷史資料

### 原則

- **小批次**、**有間隔**、**可中斷**、**可重跑**（冪等）
- 在**低峰時段**執行
- 不要用一個大 SELECT 撈全表 — 按主鍵範圍分批

```go
// 回填腳本 — 按 ID 範圍分批處理
func BackfillOrderDetails(db *gorm.DB) error {
    batchSize := 500
    lastID := int64(0)

    for {
        var orders []OldOrder // 包含所有舊欄位的 Model
        result := db.Raw(`
            SELECT id, shipping_name, shipping_phone, shipping_address,
                   invoice_title, invoice_tax_id, notes, metadata, created_at, updated_at
            FROM orders
            WHERE id > ?
            ORDER BY id ASC
            LIMIT ?
        `, lastID, batchSize).Scan(&orders)

        if result.Error != nil {
            return result.Error
        }
        if len(orders) == 0 {
            break // 全部處理完
        }

        // 批次 UPSERT（冪等 — 重跑不會重複）
        for _, o := range orders {
            db.Exec(`
                INSERT INTO order_details
                    (order_id, shipping_name, shipping_phone, shipping_address,
                     invoice_title, invoice_tax_id, notes, metadata, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON DUPLICATE KEY UPDATE
                    shipping_name = VALUES(shipping_name),
                    shipping_phone = VALUES(shipping_phone),
                    shipping_address = VALUES(shipping_address),
                    invoice_title = VALUES(invoice_title),
                    invoice_tax_id = VALUES(invoice_tax_id),
                    notes = VALUES(notes),
                    metadata = VALUES(metadata),
                    updated_at = VALUES(updated_at)
            `, o.ID, o.ShippingName, o.ShippingPhone, o.ShippingAddress,
                o.InvoiceTitle, o.InvoiceTaxID, o.Notes, o.Metadata,
                o.CreatedAt, o.UpdatedAt)
        }

        lastID = orders[len(orders)-1].ID

        log.Info("backfill progress", "last_id", lastID, "batch", len(orders))

        // 每批之間休息，避免打爆 DB
        time.Sleep(100 * time.Millisecond)
    }

    log.Info("backfill completed")
    return nil
}
```

### 注意事項

```
┌─────────────────────────────────────────────────────┐
│  回填的常見陷阱                                       │
│                                                     │
│  ❌ SELECT * FROM orders                             │
│     → 全表掃描，鎖表、打爆記憶體                      │
│                                                     │
│  ✅ WHERE id > ? ORDER BY id LIMIT 500              │
│     → 利用主鍵順序讀，不鎖表，記憶體可控              │
│                                                     │
│  ❌ 沒有冪等設計，重跑會重複插入                       │
│     → ON DUPLICATE KEY UPDATE 保證冪等               │
│                                                     │
│  ❌ 回填期間沒有雙寫                                  │
│     → 先開雙寫 (Phase 2) 再回填 (Phase 3)            │
│     → 否則回填期間的新寫入會漏掉                      │
└─────────────────────────────────────────────────────┘
```

> **重點**：**必須先開雙寫再回填**。順序不能反。如果先回填再開雙寫，回填期間新建的訂單就會漏掉次要表資料。
{: .important }

---

## 六、Phase 4 — 資料驗證

### 驗證腳本

```go
// 比對兩表資料是否一致
func VerifyConsistency(db *gorm.DB) (mismatches int, missing int, err error) {
    batchSize := 1000
    lastID := int64(0)

    for {
        var rows []struct {
            OrderID         int64
            OldShippingName string
            NewShippingName sql.NullString
            DetailExists    bool
        }

        db.Raw(`
            SELECT
                o.id AS order_id,
                o.shipping_name AS old_shipping_name,
                d.shipping_name AS new_shipping_name,
                (d.id IS NOT NULL) AS detail_exists
            FROM orders o
            LEFT JOIN order_details d ON o.id = d.order_id
            WHERE o.id > ?
            ORDER BY o.id ASC
            LIMIT ?
        `, lastID, batchSize).Scan(&rows)

        if len(rows) == 0 {
            break
        }

        for _, r := range rows {
            if !r.DetailExists {
                missing++
                log.Warn("missing order_detail", "order_id", r.OrderID)
            } else if r.OldShippingName != r.NewShippingName.String {
                mismatches++
                log.Warn("data mismatch",
                    "order_id", r.OrderID,
                    "old", r.OldShippingName,
                    "new", r.NewShippingName.String)
            }
        }

        lastID = rows[len(rows)-1].OrderID
    }

    log.Info("verification done", "missing", missing, "mismatches", mismatches)
    return
}
```

**驗證標準**：
- `missing == 0`：沒有遺漏的記錄
- `mismatches == 0`：沒有不一致的資料
- 連續跑 3 次驗證（隔一段時間跑一次），全部通過才進下一階段

---

## 七、Phase 5 — 切讀到新表

### 漸進式切流

```
不要一次切 100% 流量，用灰度逐步切：

  Day 1:  1% 流量讀新表 → 觀察錯誤率、延遲
  Day 2:  10% 流量讀新表
  Day 3:  50% 流量讀新表
  Day 5:  100% 流量讀新表
```

```go
// 讀取層 — 根據 Feature Flag 決定讀哪張表
func GetOrderDetail(ctx context.Context, db *gorm.DB, orderID int64) (*OrderDetailDTO, error) {
    cfg := GetSplitConfig()

    if cfg.ReadFromNew {
        // 讀新表
        var detail OrderDetail
        if err := db.Where("order_id = ?", orderID).First(&detail).Error; err != nil {
            if errors.Is(err, gorm.ErrRecordNotFound) {
                // 降級：新表沒找到，fallback 讀舊表（防止回填遺漏）
                return getOrderDetailFromOldTable(db, orderID)
            }
            return nil, err
        }
        return toDTO(&detail), nil
    }

    // 讀舊表（Phase 5 之前的預設行為）
    return getOrderDetailFromOldTable(db, orderID)
}

func getOrderDetailFromOldTable(db *gorm.DB, orderID int64) (*OrderDetailDTO, error) {
    var order struct {
        ShippingName    string
        ShippingPhone   string
        ShippingAddress string
        InvoiceTitle    string
        InvoiceTaxID    string
        Notes           string
    }
    err := db.Raw(`
        SELECT shipping_name, shipping_phone, shipping_address,
               invoice_title, invoice_tax_id, notes
        FROM orders WHERE id = ?
    `, orderID).Scan(&order).Error

    if err != nil {
        return nil, err
    }
    return &OrderDetailDTO{
        ShippingName:    order.ShippingName,
        ShippingPhone:   order.ShippingPhone,
        ShippingAddress: order.ShippingAddress,
        InvoiceTitle:    order.InvoiceTitle,
        InvoiceTaxID:    order.InvoiceTaxID,
        Notes:           order.Notes,
    }, nil
}
```

### 切讀後的監控指標

| 監控項目 | 正常標準 | 異常處理 |
|:-----|:-----|:-----|
| API 錯誤率 | 不高於切流前 | 立刻關 Flag 切回舊表 |
| P99 延遲 | 不高於切流前 20% | 檢查新表索引 |
| Fallback 觸發次數 | 接近 0 | 有就是回填遺漏，補資料 |
| order_details 查詢 QPS | 符合預期 | 與原本的 orders 查詢比對 |

---

## 八、Phase 6 — 清理舊欄位

> **重點**：這是整個流程中風險最高的一步，必須確認上一步已穩定運行 2-4 週以上才執行。刪了就回不去。
{: .important }

### 為什麼不直接 ALTER TABLE DROP COLUMN？

```
ALTER TABLE orders DROP COLUMN shipping_name;

問題：
  1. 大表 DDL 會鎖表（MySQL < 8.0 的部分情況）
  2. 即使 Online DDL 不鎖表，也會消耗大量磁碟 I/O
  3. 長時間 DDL 執行期間如果失敗，需要重來
  4. 沒有回滾機會

解法：用 gh-ost 進行線上 DDL
```

### 用 gh-ost 刪除舊欄位

```bash
# gh-ost 原理：
#   1. 建立一張 _gho 影子表（新 schema）
#   2. 訂閱 binlog，持續同步增量資料
#   3. 小批次複製歷史資料
#   4. 完成後原子性 RENAME 切換表名
#
# 全程不鎖表、可暫停、可中止

gh-ost \
  --host=127.0.0.1 \
  --port=3306 \
  --user=admin \
  --password='xxx' \
  --database=mydb \
  --table=orders \
  --alter="DROP COLUMN shipping_name, DROP COLUMN shipping_phone, DROP COLUMN shipping_address, DROP COLUMN invoice_title, DROP COLUMN invoice_tax_id, DROP COLUMN notes, DROP COLUMN metadata" \
  --chunk-size=1000 \
  --max-load='Threads_running=25' \
  --critical-load='Threads_running=50' \
  --initially-drop-ghost-table \
  --initially-drop-old-table \
  --execute
```

```
gh-ost 執行流程：

┌─────────┐        ┌─────────────┐
│ orders  │        │ _orders_gho │  ← 新 schema（沒有次要欄位）
│ (原表)   │        │ (影子表)     │
└────┬────┘        └──────┬──────┘
     │                     │
     │  1. 小批次複製       │
     │ ──────────────────→ │
     │                     │
     │  2. Binlog 持續同步  │
     │ ──────────────────→ │
     │                     │
     │  3. 資料追平後       │
     │                     │
     ├── RENAME orders → _orders_old
     └── RENAME _orders_gho → orders  ← 原子切換
```

### 清理步驟

```
1. 確認 ReadFromNew = true 且穩定運行 2-4 週
2. 關閉 WriteOldDetail（停止寫舊表的次要欄位）
3. 觀察 1 週確認無問題
4. 用 gh-ost 移除舊表的次要欄位
5. 清理程式碼中的 Feature Flag 和舊讀取邏輯
6. 移除 _orders_old 備份表（再等 1-2 週）
```

---

## 九、完整時間軸總覽

```
Week 1                Week 2               Week 3               Week 4+
─────────────────────────────────────────────────────────────────────────
│                     │                    │                    │
├ Day 1: 建立         ├ Day 8: 驗證完成    ├ Day 15: 100%讀新表 ├ Day 30+:
│ order_details       │ 連續3次驗證通過     │ 關閉 Fallback      │ gh-ost 刪舊欄位
│                     │                    │                    │
├ Day 2: 部署雙寫     ├ Day 9: 灰度1%     ├ Day 16-28:         ├ 清理程式碼
│ DualWrite = true    │ ReadFromNew = 1%   │ 持續監控            │ 移除 Feature Flag
│                     │                    │                    │
├ Day 3-5: 回填       ├ Day 10: 灰度10%   │                    │
│ 低峰期執行           │                    │                    │
│                     ├ Day 12: 灰度50%   │                    │
├ Day 6-7: 驗證       │                    │                    │
│ 跑 3 次比對腳本      ├ Day 14: 灰度100%  │                    │
│                     │                    │                    │
─────────────────────────────────────────────────────────────────────────
```

---

## 十、Rollback 策略

每個階段都有對應的退回方案：

| 階段 | 異常狀況 | 回滾動作 |
|:-----|:-----|:-----|
| **Phase 1** 建表 | 表結構不對 | `DROP TABLE order_details` |
| **Phase 2** 雙寫 | 次要表寫入大量失敗 | 關閉 `DualWriteEnabled` Flag |
| **Phase 3** 回填 | 回填太慢打爆 DB | 停腳本、調 batch size 和 sleep |
| **Phase 4** 驗證 | 大量不一致 | 排查雙寫 Bug → 清空新表 → 修 Bug → 重跑 Phase 2-4 |
| **Phase 5** 切讀 | 新表讀取報錯或延遲高 | 關閉 `ReadFromNew` Flag → 自動切回舊表 |
| **Phase 6** 刪欄位 | gh-ost 執行異常 | gh-ost 本身可暫停/中止；已完成的用 `_old` 備份表恢復 |

> **重點**：Phase 6 之前的所有階段，舊表的資料都還在、舊的讀取邏輯都還在。**只要 Flag 一關，系統立刻回到拆分前的狀態**。這就是 Feature Flag 的價值 — 讓每一步都可逆。
{: .note }

---

## 十一、常見問題

### Q: 雙寫要用分散式交易嗎？

```
A: 不用。因為兩張表在同一個 MySQL 實例，用本地 Transaction 即可。
   如果核心表和次要表在不同 DB，才需要考慮分散式交易或最終一致性。

   同一個 DB:
     db.Transaction(func(tx *gorm.DB) error {
         tx.Create(&order)
         tx.Create(&detail)  // 同一個 TX，保證原子
         return nil
     })
```

### Q: 讀取需要 JOIN 嗎？

```
A: 盡量不要。拆表的目的就是讓核心查詢不碰次要資料。

   列表頁 → 只查 orders（核心表）
   詳情頁 → 先查 orders，再查 order_details（兩次查詢）

   如果確實需要 JOIN（如匯出報表），用離線查詢或讀 Slave。
```

### Q: 如果回填跑到一半失敗了？

```
A: 因為用了 ON DUPLICATE KEY UPDATE，直接重跑即可。
   它會從 lastID=0 重新開始，已存在的記錄會被 UPDATE（冪等）。
   已經 INSERT 的不會重複插入。
```

### Q: 為什麼不用觸發器 (Trigger) 做雙寫？

```
A: 觸發器的問題：
   1. 難以測試和除錯
   2. 增加 DB 層的隱藏複雜度
   3. 無法加業務邏輯（如失敗重試、記 log）
   4. 效能影響不透明
   5. 團隊成員可能不知道有觸發器存在

   應用層雙寫的優勢：
   1. 邏輯透明，Code Review 可見
   2. 可以用 Feature Flag 隨時開關
   3. 失敗處理完全可控
   4. 可以加監控指標
```

### Q: 大表幾千萬筆，回填要跑多久？

```
A: 估算方式：
   假設 5000 萬筆，batch_size=500，sleep=100ms

   批次數 = 50,000,000 / 500 = 100,000 批
   每批耗時 ≈ 50ms (寫入) + 100ms (sleep) = 150ms
   總耗時 ≈ 100,000 × 150ms = 15,000s ≈ 4.2 小時

   加速方式：
   1. 在 Slave 上跑 SELECT，Master 上跑 INSERT
   2. 加大 batch_size（觀察 DB 負載）
   3. 縮短 sleep（低峰期）
   4. 開多個 Worker 分不同 ID 範圍平行跑
```

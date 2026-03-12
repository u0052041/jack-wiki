---
layout: default
title: 資料庫底層原理
parent: 系統設計
nav_order: 2
---

# 資料庫底層原理：ACID、索引、鎖與資料結構
{: .no_toc }

從交易機制到 B+ Tree 索引的完整剖析
{: .fs-6 .fw-300 }

## 目錄
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## 一、ACID 原則

### 什麼是 ACID？

ACID 是關聯式資料庫保證交易 (Transaction) 可靠性的四大特性：

| 特性 | 說明 | 白話解釋 |
|:-----|:-----|:-----|
| **A (Atomicity)** | 交易中的操作全部成功或全部失敗 | 「要嘛全做，要嘛全不做」 |
| **C (Consistency)** | 交易前後資料必須符合所有規則與約束 | 資料永遠合法 |
| **I (Isolation)** | 並發交易之間互不干擾 | 多人同時操作也不會亂 |
| **D (Durability)** | 交易一旦提交，結果永久保存 | 寫入成功就不會丟失 |

### Atomicity — 原子性

```
-- 轉帳範例：A 轉 100 元給 B
BEGIN TRANSACTION;
  UPDATE accounts SET balance = balance - 100 WHERE user = 'A';
  UPDATE accounts SET balance = balance + 100 WHERE user = 'B';
COMMIT;

-- 如果任一步失敗 → 全部 ROLLBACK
-- 不會出現 A 扣了錢但 B 沒收到的情況
```

**底層實現**：
- **Undo Log (回滾日誌)**：記錄每個操作的反向操作，失敗時用來回滾
- **Redo Log (重做日誌)**：記錄修改後的值，崩潰恢復時用來重做已提交的交易

```
         寫入操作
            │
   ┌────────┼────────┐
   ▼        ▼        ▼
Undo Log  Buffer   Redo Log
(回滾用)   Pool    (恢復用)
            │
            ▼
         磁碟 (Disk)
```

### Consistency — 一致性

```sql
-- 約束範例：餘額不能為負
ALTER TABLE accounts ADD CONSTRAINT chk_balance CHECK (balance >= 0);

-- 違反約束 → 交易自動失敗
UPDATE accounts SET balance = -50 WHERE user = 'A';
-- Error: CHECK constraint failed
```

- 一致性是**目的**，由 Atomicity + Isolation + 應用層邏輯共同保證
- 包含：主鍵約束、外鍵約束、唯一約束、CHECK 約束、觸發器

### Isolation — 隔離性

#### 四種隔離等級

| 隔離等級 | 髒讀 | 不可重複讀 | 幻讀 | 效能 |
|:-----|:-----|:-----|:-----|:-----|
| **Read Uncommitted** | 可能 | 可能 | 可能 | 最高 |
| **Read Committed** | 防止 | 可能 | 可能 | 高 |
| **Repeatable Read** | 防止 | 防止 | 可能 | 中 |
| **Serializable** | 防止 | 防止 | 防止 | 最低 |

> **重點**：MySQL InnoDB 預設是 **Repeatable Read**，PostgreSQL 預設是 **Read Committed**。MySQL 在 RR 等級下透過 Next-Key Lock 額外防止了大部分幻讀情況。
{: .note }

#### 三種讀取異常

```
【髒讀 Dirty Read】
  TX1: UPDATE balance = 50  (未 COMMIT)
  TX2: SELECT balance → 讀到 50（但 TX1 可能 ROLLBACK！）

【不可重複讀 Non-Repeatable Read】
  TX1: SELECT balance → 100
  TX2: UPDATE balance = 50; COMMIT;
  TX1: SELECT balance → 50（同一交易內讀到不同值）

【幻讀 Phantom Read】
  TX1: SELECT COUNT(*) WHERE age > 20 → 5 筆
  TX2: INSERT INTO users(age) VALUES(25); COMMIT;
  TX1: SELECT COUNT(*) WHERE age > 20 → 6 筆（多了一筆幻影）
```

#### MVCC — 多版本並發控制

大多數資料庫用 MVCC 實現隔離性（而非單純加鎖），每筆資料保留多個版本：

```
Row: user='A'
  Version 1: balance=100  (created by TX 10, expired by TX 15)
  Version 2: balance=50   (created by TX 15, active)

TX 12 (Read Committed)  → 讀 Version 1 (TX 10 已提交)
TX 16 (Read Committed)  → 讀 Version 2 (TX 15 已提交)
TX 14 (Repeatable Read) → 始終讀 Version 1 (快照在 TX 14 開始時建立)
```

| 隔離等級 | MVCC 行為 |
|:-----|:-----|
| **Read Committed** | 每次 SELECT 都取最新的已提交快照 |
| **Repeatable Read** | 交易開始時建立快照，整個交易期間用同一快照 |

**InnoDB MVCC 實作細節**：

```
每一行隱藏欄位：
┌──────────┬──────────────┬──────────────┬──────────┐
│ 實際資料  │ DB_TRX_ID    │ DB_ROLL_PTR  │ DB_ROW_ID│
│          │ (最後修改的   │ (指向 Undo   │ (隱藏主鍵)│
│          │  交易 ID)    │  Log 的指標) │          │
└──────────┴──────────────┴──────────────┴──────────┘

Read View（快照）包含：
  - m_ids:      當前所有活躍（未提交）的交易 ID 列表
  - min_trx_id: m_ids 中最小的值
  - max_trx_id: 下一個將分配的交易 ID
  - creator_id: 建立此 Read View 的交易 ID

可見性判斷：
  if (row.trx_id < min_trx_id) → 可見（交易已提交）
  if (row.trx_id >= max_trx_id) → 不可見（交易在快照後才開始）
  if (row.trx_id in m_ids)     → 不可見（交易未提交）
  else                          → 可見（交易已提交）
```

### Durability — 持久性

```
                    COMMIT
                      │
        ┌─────────────┼─────────────┐
        ▼             ▼             ▼
   Write-Ahead    fsync/          Replication
     Log (WAL)    fdatasync       (HA 架構)
        │             │
   先寫日誌      強制刷到磁碟
   再改資料
```

| 機制 | 說明 |
|:-----|:-----|
| **WAL (Write-Ahead Log)** | 先寫日誌、再寫資料頁，崩潰後可重播日誌恢復 |
| **fsync** | 強制將 OS buffer 刷寫到磁碟，確保不在記憶體中丟失 |
| **Checkpoint** | 定期將記憶體中的髒頁寫入磁碟，縮短恢復時間 |
| **Replication** | 同步/半同步複製到其他節點，防止單點故障 |

---

## 二、B+ Tree 索引

### 為什麼用 B+ Tree？

```
磁碟讀取的特性：
  隨機讀取一次 ≈ 10ms（尋道時間）
  循序讀取 1MB ≈ 1ms

結論：要最小化磁碟 I/O 次數 → 每次讀一整頁（通常 16KB）
     → 需要「矮胖」的樹結構 → B+ Tree
```

| 資料結構 | 樹高 (100 萬筆) | 磁碟 I/O 次數 | 適合磁碟？ |
|:-----|:-----|:-----|:-----|
| 二元搜尋樹 | ~20 層 | ~20 次 | 不適合 |
| AVL / 紅黑樹 | ~20 層 | ~20 次 | 不適合 |
| B Tree | ~3 層 | ~3 次 | 適合 |
| **B+ Tree** | **~3 層** | **~3 次** | **最適合** |

### B+ Tree 結構

```
                     ┌──────────────────┐
                     │  [30]  [60]      │  ← 根節點（只存 key）
                     └──┬───┬───┬───────┘
                   ╱    │       │    ╲
         ┌────────┘     │       │     └────────┐
         ▼              ▼       ▼              ▼
  ┌────────────┐ ┌────────────┐ ┌────────────┐
  │[10] [20]   │ │[35] [45]   │ │[70] [80]   │  ← 內部節點
  └─┬──┬──┬────┘ └─┬──┬──┬────┘ └─┬──┬──┬────┘
    ▼  ▼  ▼        ▼  ▼  ▼        ▼  ▼  ▼
  ┌──┐┌──┐┌──┐  ┌──┐┌──┐┌──┐  ┌──┐┌──┐┌──┐
  │5 ││15││25│  │32││40││50│  │65││75││90│    ← 葉節點（存 key+data）
  │ →││ →││ →│  │ →││ →││ →│  │ →││ →││→ │
  └──┘└──┘└──┘  └──┘└──┘└──┘  └──┘└──┘└──┘
   ↔    ↔   ↔    ↔    ↔   ↔    ↔    ↔   ↔
   └────┴───┴────┴────┴───┴────┴────┴───┘
              葉節點形成雙向鏈結串列
```

### B+ Tree vs B Tree

| 比較 | B Tree | B+ Tree |
|:-----|:-----|:-----|
| 資料存放 | 所有節點都存資料 | **只有葉節點存資料** |
| 葉節點鏈結 | 沒有 | **雙向鏈結串列** |
| 範圍查詢 | 需要中序遍歷整棵樹 | **沿鏈結串列掃描即可** |
| 每個節點能放的 key | 較少（因為也存 data） | **較多（內部只存 key）** |
| 樹高 | 相對較高 | **相對較矮** → I/O 更少 |
| 查詢穩定性 | 不穩定（可能在根就找到） | **穩定（一定走到葉節點）** |

> **重點**：B+ Tree 的核心優勢 — ① 內部節點不存資料，一頁能放更多 key → 樹更矮 → I/O 更少 ② 葉節點有鏈結串列 → 範圍查詢 (`BETWEEN`, `ORDER BY`, `>`, `<`) 極度高效。
{: .note }

### 聚簇索引 vs 非聚簇索引

```
【聚簇索引 Clustered Index — 主鍵索引】
  葉節點直接存「整筆資料」

  B+ Tree 葉節點: [PK=1, name="Alice", age=25, ...]
                  [PK=2, name="Bob", age=30, ...]
                  [PK=3, name="Carol", age=28, ...]

  → 一張表只能有一個聚簇索引
  → InnoDB 的主鍵就是聚簇索引


【非聚簇索引 Secondary Index — 二級索引】
  葉節點存「索引欄位值 + 主鍵值」

  B+ Tree 葉節點: [name="Alice", PK=1]
                  [name="Bob", PK=2]
                  [name="Carol", PK=3]

  → 查到主鍵後，還要「回表」到聚簇索引取完整資料
```

```
SELECT * FROM users WHERE name = 'Bob';

步驟：
  1. 走 name 的 B+ Tree → 找到 PK=2          (二級索引)
  2. 拿 PK=2 去主鍵 B+ Tree → 取出完整資料     (回表)
        ^^^^
        這一步叫「回表查詢」

如何避免回表？ → 覆蓋索引 (Covering Index)
  CREATE INDEX idx_name_age ON users(name, age);
  SELECT name, age FROM users WHERE name = 'Bob';
  → 索引葉節點已包含所需欄位，不需要回表！
```

### 索引失效的常見情況

```sql
-- 假設有索引: INDEX idx_abc (a, b, c)

-- ✅ 走索引（最左前綴匹配）
WHERE a = 1
WHERE a = 1 AND b = 2
WHERE a = 1 AND b = 2 AND c = 3

-- ❌ 不走索引（跳過最左欄位）
WHERE b = 2
WHERE b = 2 AND c = 3
WHERE c = 3

-- ❌ 索引失效的其他情況
WHERE a + 1 = 2          -- 對索引欄位做運算
WHERE LEFT(name, 3) = 'abc'  -- 對索引欄位使用函式
WHERE name LIKE '%abc'   -- 前導萬用字元
WHERE name != 'abc'      -- 否定條件（某些情況）
WHERE age IS NULL        -- 看優化器判斷（不一定失效）
```

> **重點**：索引是否使用最終由**查詢優化器**決定。即使符合最左前綴，如果優化器判斷全表掃描更快（例如小表或選擇性低），也可能不走索引。用 `EXPLAIN` 確認。
{: .important }

---

## 三、鎖機制

### 悲觀鎖 vs 樂觀鎖

```
┌──────────────────────────────────────────────────────────┐
│  悲觀鎖 (Pessimistic Lock)                                │
│  「我覺得一定會衝突，先鎖起來再操作」                        │
│  → SELECT ... FOR UPDATE / LOCK IN SHARE MODE            │
│  → 適合寫入頻繁、衝突率高的場景                            │
│                                                          │
│  樂觀鎖 (Optimistic Lock)                                 │
│  「我覺得不太會衝突，先做再說，提交時檢查有沒有被改過」       │
│  → Version 欄位 / CAS / Redis WATCH                      │
│  → 適合讀多寫少、衝突率低的場景                            │
└──────────────────────────────────────────────────────────┘
```

| 比較 | 悲觀鎖 | 樂觀鎖 |
|:-----|:-----|:-----|
| 加鎖時機 | 操作前加鎖 | 不加鎖，提交時才檢查 |
| 衝突處理 | 阻塞等待 | 失敗重試 |
| 效能 | 有鎖等待開銷 | 無鎖等待，但重試有開銷 |
| 適用場景 | 高衝突（搶購、扣庫存） | 低衝突（更新個人資料） |
| 死鎖風險 | 有 | 無 |

### 悲觀鎖 — SELECT FOR UPDATE

```sql
-- 排他鎖（寫鎖）：其他交易不能讀也不能寫
BEGIN;
SELECT * FROM accounts WHERE id = 1 FOR UPDATE;
-- 此時 id=1 這行被鎖住，其他交易的 FOR UPDATE / UPDATE 會等待
UPDATE accounts SET balance = balance - 100 WHERE id = 1;
COMMIT;  -- 鎖釋放

-- 共享鎖（讀鎖）：其他交易可以讀，但不能寫
BEGIN;
SELECT * FROM accounts WHERE id = 1 FOR SHARE;  -- MySQL 8.0+
-- 或 LOCK IN SHARE MODE (舊語法)
```

```
時間軸範例：

TX A                                  TX B
  │                                     │
  │── BEGIN                             │── BEGIN
  │── SELECT ... FOR UPDATE (id=1)      │
  │── 取得鎖 ✓                          │
  │                                     │── SELECT ... FOR UPDATE (id=1)
  │── UPDATE balance = 900              │── 等待中... ⏳（被鎖阻塞）
  │── COMMIT                            │
  │── 鎖釋放                             │── 取得鎖 ✓（繼續執行）
  │                                     │── UPDATE balance = 800
  │                                     │── COMMIT
```

**Go 實作 — GORM 悲觀鎖**：

```go
func DeductWithPessimisticLock(db *gorm.DB, userID int64, amount int) error {
    return db.Transaction(func(tx *gorm.DB) error {
        var account Account

        // ① SELECT ... FOR UPDATE（在交易內加行鎖）
        if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
            First(&account, userID).Error; err != nil {
            return err
        }

        // ② 業務邏輯（此時其他交易無法修改此行）
        if account.Balance < amount {
            return fmt.Errorf("餘額不足")
        }

        // ③ 更新（安全，因為已持有鎖）
        return tx.Model(&account).
            Update("balance", account.Balance-amount).Error
    })
}
```

> **重點**：`FOR UPDATE` 鎖的範圍取決於 WHERE 條件走的索引。走主鍵 → 鎖行；走非唯一索引 → 可能鎖多行 (Next-Key Lock)；沒走索引 → **鎖全表**。務必確保 WHERE 條件有索引。
{: .important }

### 樂觀鎖 — Version 欄位

```sql
-- 資料表結構
CREATE TABLE products (
    id         BIGINT PRIMARY KEY,
    name       VARCHAR(100),
    stock      INT NOT NULL,
    version    INT NOT NULL DEFAULT 0,  -- 樂觀鎖版本號
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

```
流程：

  1. SELECT stock, version FROM products WHERE id = 1;
     → stock=100, version=5

  2. 業務計算：new_stock = 100 - 1 = 99

  3. UPDATE products
     SET stock = 99, version = version + 1
     WHERE id = 1 AND version = 5;
                     ^^^^^^^^^^^
                     關鍵：帶上舊的 version

  4. 檢查 affected rows：
     → 1 → 成功（version 沒變，代表沒人改過）
     → 0 → 失敗（version 已變，代表被別人改過，需重試）
```

```
時間軸範例：

TX A                                TX B
  │                                  │
  │── SELECT version → 5             │── SELECT version → 5
  │                                  │
  │── UPDATE ... WHERE version=5     │
  │── affected_rows = 1 ✓            │
  │── version 變成 6                  │
  │                                  │── UPDATE ... WHERE version=5
  │                                  │── affected_rows = 0 ❌ 失敗！
  │                                  │── 重試整個流程
```

**Go 實作 — GORM 樂觀鎖**：

```go
type Product struct {
    ID        int64  `gorm:"primaryKey"`
    Name      string
    Stock     int
    Version   int    `gorm:"not null;default:0"`
}

func DeductWithOptimisticLock(db *gorm.DB, productID int64, qty int) error {
    maxRetries := 5

    for i := 0; i < maxRetries; i++ {
        var product Product
        if err := db.First(&product, productID).Error; err != nil {
            return err
        }

        if product.Stock < qty {
            return fmt.Errorf("庫存不足：%d < %d", product.Stock, qty)
        }

        // 帶 version 條件更新
        result := db.Model(&Product{}).
            Where("id = ? AND version = ?", productID, product.Version).
            Updates(map[string]interface{}{
                "stock":   product.Stock - qty,
                "version": product.Version + 1,
            })

        if result.Error != nil {
            return result.Error
        }
        if result.RowsAffected == 1 {
            return nil
        }
        // affected_rows == 0 → 版本已變，重試
    }

    return fmt.Errorf("樂觀鎖重試 %d 次仍失敗", maxRetries)
}
```

**樂觀鎖的其他變體**：

| 方式 | WHERE 條件 | 適用場景 |
|:-----|:-----|:-----|
| **Version 欄位** | `WHERE version = old_version` | 通用，最常見 |
| **Timestamp 欄位** | `WHERE updated_at = old_timestamp` | 需要記錄更新時間的場景 |
| **條件值比對** | `WHERE stock = old_stock` | 不想加額外欄位（但有 ABA 問題） |

> **重點**：「條件值比對」有 **ABA 問題** — 值從 A 改成 B 再改回 A，比對時看起來沒變但實際上被修改過兩次。Version 遞增欄位不會有這個問題，因為 version 只增不減。
{: .important }

### InnoDB 鎖的類型

```
┌─────────────────────────────────────────────────────┐
│  粒度分類                                            │
│  ├── 表鎖 (Table Lock)    → 鎖整張表，粒度最粗       │
│  ├── 行鎖 (Row Lock)      → 鎖單行，粒度最細         │
│  └── 意向鎖 (Intention)   → 表級標記，快速判斷衝突    │
│                                                     │
│  模式分類                                            │
│  ├── 共享鎖 S (Shared)    → 讀鎖，多個 TX 可同時持有  │
│  └── 排他鎖 X (Exclusive) → 寫鎖，只有一個 TX 能持有  │
│                                                     │
│  行鎖的演算法                                        │
│  ├── Record Lock          → 鎖定單一索引記錄         │
│  ├── Gap Lock             → 鎖定索引間的間隙         │
│  └── Next-Key Lock        → Record + Gap（RR 預設）  │
└─────────────────────────────────────────────────────┘
```

#### Next-Key Lock 防幻讀

```sql
-- 假設 age 索引上有值: 10, 20, 30

-- TX1: 在 RR 隔離等級下
SELECT * FROM users WHERE age = 20 FOR UPDATE;

-- InnoDB 會加上 Next-Key Lock:
--   Record Lock: age=20 這筆
--   Gap Lock:    (10, 20) 和 (20, 30) 這兩個間隙
--
-- TX2 想要 INSERT age=15 或 age=25 → 被阻塞（防止幻讀）
```

### 死鎖

```
TX A                              TX B
  │                                 │
  │── LOCK Row 1 ✓                  │── LOCK Row 2 ✓
  │                                 │
  │── LOCK Row 2 → 等待 TX B...    │── LOCK Row 1 → 等待 TX A...
  │                                 │
  │        💀 死鎖 (Deadlock) 💀      │
```

**InnoDB 的處理方式**：
- 自動偵測死鎖（等待圖 Wait-for Graph）
- 選擇回滾**代價較小**的交易（修改行數較少的）
- 被回滾的交易收到 `ERROR 1213 (40001): Deadlock found`

**避免死鎖的實務建議**：

```go
// ❌ 不同交易以不同順序取鎖 → 死鎖風險
// TX A: lock(row1) → lock(row2)
// TX B: lock(row2) → lock(row1)

// ✅ 統一鎖定順序 → 永遠先鎖 ID 小的
func TransferSafe(db *gorm.DB, fromID, toID int64, amount int) error {
    // 保證鎖定順序一致
    firstID, secondID := fromID, toID
    if fromID > toID {
        firstID, secondID = toID, fromID
    }

    return db.Transaction(func(tx *gorm.DB) error {
        var first, second Account
        tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&first, firstID)
        tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&second, secondID)
        // ... 轉帳邏輯
        return nil
    })
}
```

---

## 四、布隆過濾器 (Bloom Filter)

### 原理

布隆過濾器用極少的記憶體判斷一個元素**是否「可能存在」**：

```
插入 "apple":
  hash1("apple") = 2
  hash2("apple") = 5
  hash3("apple") = 8

  Bit Array:
  [0] [0] [1] [0] [0] [1] [0] [0] [1] [0]
            ↑               ↑           ↑
           位置2           位置5       位置8

查詢 "banana":
  hash1("banana") = 2  → bit[2] = 1 ✓
  hash2("banana") = 4  → bit[4] = 0 ✗ → 一定不存在！

查詢 "cherry":
  hash1("cherry") = 2  → bit[2] = 1 ✓
  hash2("cherry") = 5  → bit[5] = 1 ✓
  hash3("cherry") = 8  → bit[8] = 1 ✓
  → 可能存在（也可能是誤判！）
```

| 判斷結果 | 實際意義 |
|:-----|:-----|
| **不存在** | 100% 確定不存在 |
| **存在** | 可能存在（有誤判率，False Positive） |

### 應用場景

```
【快取穿透防護】
  請求 → Bloom Filter → "一定不存在" → 直接回 404（不打 DB）
                      → "可能存在"   → 查 Redis → 查 DB

【其他場景】
  - 垃圾郵件過濾（這個 email 是否在黑名單中？）
  - 爬蟲 URL 去重（這個網址爬過了嗎？）
  - 推薦系統去重（這篇文章推薦過了嗎？）
```

**Go + Redis 實作**：

```go
import "github.com/redis/go-redis/v9"

// Redis 內建 Bloom Filter（需要 RedisBloom 模組）
// 或用 BF.ADD / BF.EXISTS 命令

// 手動實作：用 Redis BitMap 模擬
func BloomAdd(ctx context.Context, rdb *redis.Client, key string, value string) {
    for _, offset := range bloomHashes(value) {
        rdb.SetBit(ctx, key, int64(offset), 1)
    }
}

func BloomExists(ctx context.Context, rdb *redis.Client, key string, value string) bool {
    for _, offset := range bloomHashes(value) {
        bit, _ := rdb.GetBit(ctx, key, int64(offset)).Result()
        if bit == 0 {
            return false // 一定不存在
        }
    }
    return true // 可能存在
}

func bloomHashes(value string) []uint {
    h1 := fnv32(value)
    h2 := murmur32(value)
    // 用雙重雜湊模擬 k 個雜湊函式
    offsets := make([]uint, 3)
    for i := range offsets {
        offsets[i] = uint(h1+uint32(i)*h2) % 10000 // bit array 大小
    }
    return offsets
}
```

> **重點**：布隆過濾器**不支援刪除**（清除 bit 可能影響其他元素）。如果需要刪除功能，改用 **Cuckoo Filter** 或 **Counting Bloom Filter**。
{: .note }

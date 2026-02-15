---
layout: default
title: 分散式系統理論
nav_order: 12
---

# 分散式系統理論：CAP、一致性模型與分散式交易
{: .no_toc }

從 CAP 定理到跨服務交易的實務取捨
{: .fs-6 .fw-300 }

## 目錄
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## 一、CAP 定理

### 什麼是 CAP？

CAP 定理 (Brewer's Theorem) 指出，一個分散式系統最多只能同時滿足以下三項中的**兩項**：

```
           C (Consistency)
          ╱ ╲
         ╱   ╲
        ╱ 三選二 ╲
       ╱         ╲
      A ───────── P
(Availability) (Partition Tolerance)
```

| 特性 | 說明 | 白話解釋 |
|:-----|:-----|:-----|
| **C (Consistency)** | 所有節點在同一時間看到相同的資料 | 讀到的永遠是最新寫入的值 |
| **A (Availability)** | 每個請求都能收到回應（不保證是最新值） | 系統隨時能回應，不會拒絕服務 |
| **P (Partition Tolerance)** | 系統在網路分區時仍能繼續運作 | 節點之間斷線了，系統照常工作 |

> **重點**：在分散式環境中，網路分區 (P) 是無法避免的，所以實際選擇是 **CP** 或 **AP**。
{: .note }

### 三種組合

#### CP — 犧牲可用性，保證一致性

```
Client ──→ Node A (Leader)
              │
              │ 同步寫入（等所有 follower 確認）
              │
           Node B ✗ 網路斷線
              │
           回應失敗或等待
```

- **行為**：網路分區時，系統可能拒絕寫入或讀取，直到分區恢復
- **代表系統**：ZooKeeper、etcd、HBase、MongoDB（預設）、Redis Cluster（部分場景）
- **適用場景**：金融交易、分散式鎖、設定管理

#### AP — 犧牲一致性，保證可用性

```
Client A ──→ Node A          Node B ←── Client B
              │   ✗ 網路斷線    │
            寫入 X=1          讀取 X=0（舊值）
              │                │
           兩邊各自回應，資料暫時不一致
```

- **行為**：網路分區時，所有節點仍可服務，但資料可能不一致
- **代表系統**：Cassandra、DynamoDB、CouchDB、Eureka
- **適用場景**：社群貼文、購物車、DNS

#### CA — 犧牲分區容忍（實際上不存在於分散式）

- 只有單機系統（如傳統 RDBMS 單節點）才能做到
- 分散式環境下網路分區無法避免，所以 **CA 組合在分散式中不成立**

### 實務中的取捨：不是非黑即白

> **重點**：現實系統並非嚴格二選一，而是在一致性和可用性之間做「程度上」的取捨。
{: .note }

| 一致性等級 | 說明 | 範例 |
|:-----|:-----|:-----|
| **強一致性 (Strong)** | 寫入後立刻讀到最新值 | ZooKeeper、etcd |
| **最終一致性 (Eventual)** | 一段時間後資料會一致 | DynamoDB、Cassandra |
| **因果一致性 (Causal)** | 有因果關係的操作保證順序 | MongoDB (causal sessions) |
| **讀己之寫 (Read Your Writes)** | 自己寫的資料自己讀得到 | 多數應用的基本要求 |

### PACELC 延伸模型

CAP 只講「分區時」的取捨，PACELC 加入了「正常運作時」的考量：

```
if (Partition) {
    // 選 A 或 C（跟 CAP 一樣）
} else {
    // 選 Latency 或 Consistency
}
```

| 系統 | 分區時 (PAC) | 正常時 (ELC) |
|:-----|:-----|:-----|
| DynamoDB | AP | EL（低延遲優先） |
| MongoDB | CP | EC（一致性優先） |
| Cassandra | AP | EL（低延遲優先） |
| ZooKeeper | CP | EC（一致性優先） |

---

## 二、ACID vs BASE

分散式系統中，傳統 ACID 難以達成，因此有了 BASE 模型：

| 特性 | ACID | BASE |
|:-----|:-----|:-----|
| 全名 | Atomicity, Consistency, Isolation, Durability | Basically Available, Soft state, Eventually consistent |
| 一致性 | 強一致性 | 最終一致性 |
| 可用性 | 可能犧牲 | 優先保證 |
| 適用 | 傳統 RDBMS | 分散式 NoSQL |
| 代表 | MySQL, PostgreSQL | Cassandra, DynamoDB |

> **重點**：ACID 和 BASE 不是對立的，而是一個光譜。現代系統常混合使用 — 核心交易用 ACID，輔助資料用 BASE。
{: .note }

---

## 三、分散式交易

### 為什麼需要分散式交易？

單機 ACID 由資料庫保證，但微服務架構下一個業務操作跨多個服務和資料庫：

```
「使用者下單」這個操作橫跨三個服務：

┌────────────┐    ┌────────────┐    ┌────────────┐
│ 訂單服務    │    │ 庫存服務    │    │ 支付服務    │
│ 建立訂單    │    │ 扣減庫存    │    │ 扣款       │
│ (Order DB) │    │ (Stock DB) │    │ (Pay DB)   │
└────────────┘    └────────────┘    └────────────┘
       │                │                │
       └────────────────┼────────────────┘
                        │
              如何保證這三步「要嘛全成功，要嘛全失敗」？
```

### 2PC — 兩階段提交

```
           協調者 (Coordinator)
          ╱       │        ╲
         ╱        │         ╲
     參與者A   參與者B    參與者C
     (訂單)    (庫存)     (支付)

Phase 1: Prepare (投票階段)
  協調者 → 所有參與者: "準備好了嗎？"
  參與者A → 協調者: "Yes, 我準備好了"  (鎖定資源)
  參與者B → 協調者: "Yes, 我準備好了"  (鎖定資源)
  參與者C → 協調者: "Yes, 我準備好了"  (鎖定資源)

Phase 2: Commit (提交階段)
  全部 Yes → 協調者 → 所有參與者: "Commit!"
  任一 No  → 協調者 → 所有參與者: "Rollback!"
```

| 優點 | 缺點 |
|:-----|:-----|
| 強一致性，邏輯簡單 | **同步阻塞**：Prepare 後鎖住資源等 Commit |
| 有成熟實現 (XA 協議) | **單點故障**：協調者掛了，所有參與者卡住 |
| 適合傳統資料庫場景 | **效能差**：多次網路往返 + 長時間持鎖 |

> **重點**：2PC 在微服務中很少使用，因為它要求所有參與者在 Prepare 後**持鎖等待**，嚴重影響系統吞吐量。它更常見於同一資料庫群集內部 (如 MySQL XA)。
{: .important }

### TCC — Try-Confirm-Cancel

TCC 把一個交易拆成三個業務層面的操作：

```
┌─────────────────────────────────────────────────────┐
│  Try (嘗試)     → 預留資源，不真正扣除               │
│  Confirm (確認) → 正式提交，把預留變成實際扣除        │
│  Cancel (取消)  → 釋放預留的資源                     │
└─────────────────────────────────────────────────────┘
```

```
以「下單扣庫存 + 扣款」為例：

       ┌──── Try ────┐
       │              │
  庫存服務:           支付服務:
  凍結 10 件庫存      凍結 ¥100
  (stock=90,          (balance=900,
   frozen=10)          frozen=100)
       │              │
  全部 Try 成功？
  ├── Yes ──→ Confirm: 庫存 frozen-=10, 支付 frozen-=100
  └── No  ──→ Cancel:  庫存 stock+=10 frozen-=10, 支付同理
```

**Go 實作概念**：

```go
// TCC 介面 — 每個參與服務都要實現這三個方法
type TCCService interface {
    Try(ctx context.Context, txID string, req interface{}) error
    Confirm(ctx context.Context, txID string) error
    Cancel(ctx context.Context, txID string) error
}

// 庫存服務的 TCC 實作
type StockTCC struct{ db *gorm.DB }

func (s *StockTCC) Try(ctx context.Context, txID string, req interface{}) error {
    r := req.(*DeductReq)
    // 凍結庫存（不是真的扣）
    result := s.db.Model(&Product{}).
        Where("id = ? AND stock >= ?", r.ProductID, r.Qty).
        Updates(map[string]interface{}{
            "stock":  gorm.Expr("stock - ?", r.Qty),
            "frozen": gorm.Expr("frozen + ?", r.Qty),
        })
    if result.RowsAffected == 0 {
        return fmt.Errorf("庫存不足")
    }
    return nil
}

func (s *StockTCC) Confirm(ctx context.Context, txID string) error {
    // 把凍結的庫存正式扣除
    return s.db.Model(&Product{}).
        Where("tx_id = ?", txID).
        Update("frozen", gorm.Expr("frozen - qty")).Error
}

func (s *StockTCC) Cancel(ctx context.Context, txID string) error {
    // 把凍結的庫存還回去
    return s.db.Model(&Product{}).
        Where("tx_id = ?", txID).
        Updates(map[string]interface{}{
            "stock":  gorm.Expr("stock + frozen"),
            "frozen": 0,
        }).Error
}
```

| 優點 | 缺點 |
|:-----|:-----|
| 不長時間持鎖，效能好 | **業務侵入大**：每個服務都要寫 Try/Confirm/Cancel |
| Try 階段就能快速失敗 | **開發成本高**：要處理冪等、空回滾、懸掛等問題 |
| 適合高並發場景 | **最終一致**：Confirm/Cancel 可能需要重試 |

> **重點**：TCC 的三大難題 — ① **冪等性**：Confirm/Cancel 可能被重複呼叫，必須冪等 ② **空回滾**：Try 沒執行但 Cancel 被呼叫了 ③ **懸掛**：Cancel 比 Try 先到達。實務中通常搭配交易狀態表來解決。
{: .important }

### Saga 模式

Saga 把長交易拆成多個本地交易，每個本地交易有對應的**補償操作**：

```
正向流程（每一步都是獨立的本地交易）：
  T1: 建立訂單 → T2: 扣庫存 → T3: 扣款 → 完成 ✓

任一步失敗，執行反向補償：
  T1: 建立訂單 → T2: 扣庫存 → T3: 扣款失敗 ✗
                                    │
                                    ▼
  C2: 恢復庫存 ← C1: 取消訂單  ← 開始補償
```

#### 兩種執行模式

```
【Choreography — 編舞模式（事件驅動）】

訂單服務 ──(訂單已建立)──→ Message Queue
                              │
                庫存服務 ←─────┘
                   │
            ──(庫存已扣)──→ Message Queue
                              │
                支付服務 ←─────┘

優點：服務間解耦
缺點：流程分散，難以追蹤全貌


【Orchestration — 編排模式（中央協調）】

         Saga Orchestrator
        ╱       │        ╲
       ╱        │         ╲
  訂單服務   庫存服務    支付服務

協調者依序呼叫每個服務，失敗時依序呼叫補償

優點：流程清晰，集中管理
缺點：協調者是單點
```

| 優點 | 缺點 |
|:-----|:-----|
| 每步都是本地交易，無分散式鎖 | 不保證隔離性（中間狀態可見） |
| 適合長流程（如訂單流程） | 補償邏輯可能很複雜 |
| 與訊息佇列天然搭配 | 不適合需要強一致性的場景 |

### 三種方案對比

| 比較 | 2PC | TCC | Saga |
|:-----|:-----|:-----|:-----|
| 一致性 | 強一致 | 最終一致 | 最終一致 |
| 效能 | 差（持鎖等待） | 好（無長鎖） | 好（本地交易） |
| 業務侵入 | 低（資料庫支援） | 高（寫三套邏輯） | 中（寫補償邏輯） |
| 隔離性 | 有 | 有（Try 預留） | 無（中間狀態可見） |
| 適用場景 | 同一 DB 群集 | 高並發短交易 | 長流程跨服務 |
| 代表框架 | MySQL XA | ByteTCC, Seata TCC | Temporal, Seata Saga |

> **重點**：面試常見追問 — 「ACID 在分散式怎麼辦？」答案是：單機交易靠 ACID，跨服務靠分散式交易（2PC/TCC/Saga）+ 最終一致性（BASE），根據業務場景選擇方案。
{: .note }

---

## 四、理論與實務的關聯

```
                    分散式系統設計
                    ╱            ╲
               理論基礎          實際工具
              ╱      ╲              │
           CAP      ACID          Redis / DB
        (分散式)   (交易)      (快取 / 儲存)
            │        │              │
            ▼        ▼              ▼
        選 CP/AP   選隔離等級   選持久化策略
        取捨一致性  取捨效能     取捨安全性
        vs 可用性   vs 安全性    vs 效能
```

| 場景 | 理論依據 | 實務選擇 |
|:-----|:-----|:-----|
| 金融轉帳 | 需要強一致性 (CP + ACID) | 2PC / 單機 DB Transaction |
| 電商下單 | 可容忍短暫不一致 (AP + BASE) | TCC / Saga + 最終一致 |
| 快取讀取 | 可容忍舊資料 (AP) | Redis 主從 + 最終一致 |
| 分散式鎖 | 需要一致性 (CP) | Redis Redlock / etcd Lease |
| 設定中心 | 必須強一致 (CP) | etcd / ZooKeeper |

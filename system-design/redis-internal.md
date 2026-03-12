---
layout: default
title: Redis 底層原理
parent: 系統設計
nav_order: 3
---

# Redis 底層原理：架構、資料結構與實戰機制
{: .no_toc }

從單執行緒模型到高可用叢集的完整剖析
{: .fs-6 .fw-300 }

## 目錄
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## 一、Redis 為什麼快？

```
┌──────────────────────────────────────────────┐
│              Redis 高效能的核心               │
│                                              │
│  1. 純記憶體操作        → 微秒級延遲          │
│  2. 單執行緒事件迴圈     → 無鎖、無上下文切換  │
│  3. I/O 多路復用        → 少量執行緒處理大量連線│
│  4. 高效資料結構         → 為場景優化的底層實作  │
│  5. 簡單協議 (RESP)     → 解析快速            │
└──────────────────────────────────────────────┘
```

> **重點**：Redis 的「單執行緒」是指命令執行 (處理資料) 是單執行緒。從 Redis 6.0 開始，I/O 讀寫可以用多執行緒加速，但命令執行仍是單執行緒。
{: .important }

### 單執行緒模型與事件迴圈

```
             ┌──────────────┐
             │  Event Loop  │
             └──────┬───────┘
                    │
       ┌────────────┼────────────┐
       ▼            ▼            ▼
  檔案事件       時間事件       信號處理
 (File Event)  (Time Event)
       │            │
   ┌───┴───┐    ┌───┴───┐
   │ read  │    │ 定期  │
   │ write │    │ 任務  │
   │ accept│    │(持久化)│
   └───────┘    └───────┘
```

**為什麼單執行緒就夠了？**

```go
// 類比 Go 的 select 機制，Redis 用 epoll/kqueue 監聽多個連線
for {
    // I/O 多路復用：一次等待多個 socket 事件
    events := epoll_wait(epfd, ...)

    for _, event := range events {
        if event.isAccept {
            acceptClient(event.fd)
        } else if event.isReadable {
            cmd := readCommand(event.fd)
            result := executeCommand(cmd)  // 單執行緒執行，保證原子性
            writeResponse(event.fd, result)
        }
    }
}
```

- 瓶頸在**網路 I/O** 而非 CPU，單執行緒處理命令綽綽有餘
- 單執行緒 = 不需要鎖 = 無死鎖、無競爭條件
- 命令天然**原子性**（一次只執行一個命令）

---

## 二、底層資料結構

Redis 對外的 5 種基本型別，底層由多種資料結構實現：

```
┌──────────────┬───────────────────────────────────┐
│  外部型別     │  底層編碼 (Encoding)                │
├──────────────┼───────────────────────────────────┤
│  String      │  int / embstr / raw (SDS)         │
│  List        │  listpack / quicklist             │
│  Hash        │  listpack / hashtable             │
│  Set         │  intset / listpack / hashtable    │
│  Sorted Set  │  listpack / skiplist + hashtable  │
└──────────────┴───────────────────────────────────┘
```

> **重點**：Redis 會根據資料量自動選擇最省記憶體的編碼。當資料量超過閾值時，自動升級成更通用的結構。
{: .note }

### SDS — Simple Dynamic String

Redis 不用 C 原生字串，而是自訂 SDS：

```c
struct sdshdr {
    int len;      // 已使用長度
    int alloc;    // 分配的總長度
    char flags;   // 類型標記
    char buf[];   // 實際字串內容
};
```

| 特性 | C 字串 | SDS |
|:-----|:-----|:-----|
| 取長度 | O(n) 遍歷 | O(1) 直接讀 len |
| 緩衝區溢位 | 不檢查，直接寫 | 自動擴容 |
| 二進制安全 | 遇 `\0` 結束 | 用 len 判斷，可存任意二進制 |
| 記憶體分配 | 每次修改都分配 | 預分配 + 惰性釋放 |

**預分配策略**：
- `len < 1MB` → 分配 `2 × len`
- `len >= 1MB` → 每次多分配 1MB

### Skip List — 跳躍表

Sorted Set 的核心資料結構，支援 O(log n) 的查找、插入、刪除：

```
Level 4:  HEAD ──────────────────────────────────→ 90 ──→ NIL
Level 3:  HEAD ──────────→ 30 ──────────────────→ 90 ──→ NIL
Level 2:  HEAD ──→ 10 ──→ 30 ──────────→ 70 ──→ 90 ──→ NIL
Level 1:  HEAD ──→ 10 ──→ 30 ──→ 50 ──→ 70 ──→ 90 ──→ NIL
```

- 實作簡單，不需要旋轉平衡操作
- 天然支援範圍查詢（沿鏈結串列遍歷即可）
- 透過隨機層數 (P=0.25) 維持平衡，平均時間複雜度 O(log n)

### Listpack（取代 ziplist）

Redis 7.0+ 用 listpack 取代 ziplist，解決了連鎖更新問題：

```
┌────────┬─────────┬─────────┬─────────┬─────┐
│ 總位元組 │ Entry 1 │ Entry 2 │ Entry 3 │ EOF │
└────────┴─────────┴─────────┴─────────┴─────┘

每個 Entry:
┌──────────┬──────┬─────────────┐
│ encoding │ data │ entry-len   │
└──────────┴──────┴─────────────┘
```

- 小型 List/Hash/Set/ZSet 預設用 listpack（連續記憶體，省空間）
- 超過閾值後升級成專用結構

---

## 三、持久化機制

### RDB — 快照 (Snapshot)

```
┌───────────┐    fork()    ┌───────────┐
│  主程序    │ ──────────→  │  子程序    │
│ 繼續處理   │              │ 寫 RDB 檔 │
│ 客戶端請求  │              │           │
└───────────┘              └─────┬─────┘
      │                          │
      │ Copy-on-Write (COW)      │
      │ 修改的頁才複製             ▼
      │                     dump.rdb
```

```
# redis.conf
save 900 1       # 900 秒內有 1 次修改 → 觸發 RDB
save 300 10      # 300 秒內有 10 次修改 → 觸發 RDB
save 60 10000    # 60 秒內有 10000 次修改 → 觸發 RDB
```

| 優點 | 缺點 |
|:-----|:-----|
| 檔案緊湊，適合備份 | 兩次快照間的資料可能丟失 |
| 恢復速度快 | fork() 大資料集時可能卡頓 |
| 子程序不影響主程序效能 | 不適合即時備份需求 |

### AOF — 追加式檔案 (Append Only File)

```
                寫命令
                  │
     ┌────────────┼────────────┐
     ▼            ▼            ▼
  AOF Buffer    執行命令     回應客戶端
     │
     ▼ (依策略寫入)
  AOF 檔案
```

**三種 fsync 策略**：

| 策略 | 說明 | 效能 | 安全性 |
|:-----|:-----|:-----|:-----|
| `always` | 每個寫命令都 fsync | 最慢 | 最高（最多丟 1 個命令） |
| `everysec` | 每秒 fsync 一次（**預設**） | 居中 | 最多丟 1 秒資料 |
| `no` | 交給 OS 決定何時 fsync | 最快 | 可能丟較多資料 |

### AOF Rewrite — 重寫壓縮

```
# 重寫前 (6 個命令)
SET counter 1
INCR counter
INCR counter
INCR counter
DEL temp
SET name Redis

# 重寫後 (2 個命令，效果相同)
SET counter 4
SET name Redis
```

### 混合持久化（Redis 4.0+）

```
┌──────────────────────────────┐
│         AOF 檔案              │
│  ┌─────────────────────────┐ │
│  │ RDB 格式（前半段快照）    │ │
│  ├─────────────────────────┤ │
│  │ AOF 格式（後半段增量命令）│ │
│  └─────────────────────────┘ │
└──────────────────────────────┘
```

- **優勢**：結合 RDB 快速恢復 + AOF 低資料遺失
- **啟用**：`aof-use-rdb-preamble yes`（Redis 4.0+ 預設開啟）

---

## 四、記憶體管理與淘汰策略

### 記憶體淘汰策略

當記憶體超過 `maxmemory` 時，Redis 根據策略淘汰 key：

| 策略 | 範圍 | 說明 |
|:-----|:-----|:-----|
| `noeviction` | — | 不淘汰，寫入直接報錯（**預設**） |
| `allkeys-lru` | 所有 key | 淘汰最久沒使用的 key |
| `allkeys-lfu` | 所有 key | 淘汰使用頻率最低的 key |
| `allkeys-random` | 所有 key | 隨機淘汰 |
| `volatile-lru` | 有 TTL 的 key | 淘汰最久沒使用的 |
| `volatile-lfu` | 有 TTL 的 key | 淘汰使用頻率最低的 |
| `volatile-random` | 有 TTL 的 key | 隨機淘汰 |
| `volatile-ttl` | 有 TTL 的 key | 淘汰 TTL 最短的 |

> **重點**：Redis 的 LRU 是近似 LRU，隨機抽樣 `maxmemory-samples`（預設 5）個 key，淘汰最舊的。不是真正的全域 LRU，這是效能和精確度的取捨。
{: .important }

### 過期 Key 刪除策略

Redis 對過期 key 採用**惰性刪除 + 定期刪除**雙重策略：

```
┌─────────────────────────────────────────────┐
│            過期刪除策略                       │
│                                             │
│  1. 惰性刪除 (Lazy Expiration)              │
│     → 訪問 key 時才檢查是否過期              │
│     → 過期了就刪除，沒人訪問就一直留著        │
│                                             │
│  2. 定期刪除 (Active Expiration)             │
│     → 每 100ms 隨機抽 20 個有 TTL 的 key    │
│     → 刪除其中已過期的                       │
│     → 如果過期比例 > 25%，再抽一輪           │
│     → 限制執行時間，避免阻塞主執行緒          │
└─────────────────────────────────────────────┘
```

---

## 五、Pipeline & Lua Script

### Pipeline — 批次命令

```
【沒有 Pipeline】— 每個命令都是一次網路往返 (RTT)
  Client → SET a 1 → Server
  Client ← OK       ← Server
  Client → SET b 2 → Server
  Client ← OK       ← Server
  Client → SET c 3 → Server
  Client ← OK       ← Server
  共 3 次 RTT

【有 Pipeline】— 一次送出多個命令
  Client → SET a 1 ─┐
           SET b 2  ├→ Server（一次送出）
           SET c 3 ─┘
  Client ← OK ──────┐
           OK       ├← Server（一次回收）
           OK ──────┘
  共 1 次 RTT
```

**Go 實作**：

```go
// 一般方式：3 次 RTT
rdb.Set(ctx, "a", 1, 0)
rdb.Set(ctx, "b", 2, 0)
rdb.Set(ctx, "c", 3, 0)

// Pipeline：1 次 RTT
pipe := rdb.Pipeline()
pipe.Set(ctx, "a", 1, 0)
pipe.Set(ctx, "b", 2, 0)
pipe.Set(ctx, "c", 3, 0)
cmds, err := pipe.Exec(ctx)  // 一次送出、一次回收
```

> **重點**：Pipeline 只是減少網路往返，**不保證原子性**。命令之間可能被其他 client 的命令插入。需要原子性用 MULTI/EXEC 或 Lua Script。
{: .note }

### Lua Script — 原子執行

```lua
-- 例：限流器 — 檢查 + 遞增 + 設定過期，一次原子完成
-- KEYS[1] = 限流 key, ARGV[1] = 上限, ARGV[2] = 過期秒數
local current = redis.call("GET", KEYS[1])
if current and tonumber(current) >= tonumber(ARGV[1]) then
    return 0  -- 超過限流
end
current = redis.call("INCR", KEYS[1])
if tonumber(current) == 1 then
    redis.call("EXPIRE", KEYS[1], ARGV[2])
end
return 1  -- 允許通過
```

**Go 實作**：

```go
var rateLimitScript = redis.NewScript(`
    local current = redis.call("GET", KEYS[1])
    if current and tonumber(current) >= tonumber(ARGV[1]) then
        return 0
    end
    current = redis.call("INCR", KEYS[1])
    if tonumber(current) == 1 then
        redis.call("EXPIRE", KEYS[1], ARGV[2])
    end
    return 1
`)

func AllowRequest(ctx context.Context, rdb *redis.Client, key string, limit int, windowSec int) (bool, error) {
    result, err := rateLimitScript.Run(ctx, rdb, []string{key}, limit, windowSec).Int()
    if err != nil {
        return false, err
    }
    return result == 1, nil
}
```

| 比較 | Pipeline | MULTI/EXEC | Lua Script |
|:-----|:-----|:-----|:-----|
| 原子性 | 無 | 有（批次執行） | 有（單執行緒執行） |
| 可包含邏輯 | 無 | 無（只能排隊命令） | **有**（if/else/loop） |
| 網路往返 | 1 次 | 1 次 | 1 次 |
| 適用 | 批次寫入/讀取 | 簡單原子批次 | 需要邏輯判斷的原子操作 |

> **重點**：Lua Script 在 Redis 中是**原子執行**的（整個 script 不會被其他命令打斷），但也意味著長時間的 Lua Script 會阻塞其他所有命令。務必保持 Script 簡短。
{: .important }

---

## 六、高可用架構

### Sentinel 哨兵模式

```
┌──────────┐  ┌──────────┐  ┌──────────┐
│Sentinel 1│  │Sentinel 2│  │Sentinel 3│   ← 監控叢集（奇數個）
└────┬─────┘  └────┬─────┘  └────┬─────┘
     │              │              │
     └──────────────┼──────────────┘
                    │ 監控
                    ▼
              ┌──────────┐
              │  Master  │
              └────┬─────┘
              ╱         ╲
     ┌────────┐       ┌────────┐
     │ Slave 1│       │ Slave 2│
     └────────┘       └────────┘
```

**Sentinel 的三大功能**：

| 功能 | 說明 |
|:-----|:-----|
| **監控 (Monitoring)** | 定期 PING Master/Slave，檢查是否存活 |
| **通知 (Notification)** | 故障時透過 Pub/Sub 或 API 通知管理員/應用 |
| **自動故障轉移 (Failover)** | Master 掛了 → 選一個 Slave 晉升為新 Master |

**故障轉移流程**：

```
1. 主觀下線 (SDOWN)
   Sentinel 1 PING Master → 超時無回應
   → Sentinel 1 認為 Master 主觀下線

2. 客觀下線 (ODOWN)
   Sentinel 1 詢問其他 Sentinel: "你們也覺得 Master 掛了嗎？"
   → 超過 quorum (法定人數) 的 Sentinel 同意
   → Master 被標記為客觀下線

3. 選舉 Leader Sentinel
   由 Leader Sentinel 主導故障轉移（Raft 演算法選舉）

4. 選擇新 Master
   從 Slave 中選擇：
   ① 優先順序 (replica-priority) 最小的
   ② 複製偏移量 (replication offset) 最大的（資料最新）
   ③ Run ID 最小的（字典序）

5. 執行切換
   → 對選中的 Slave 執行 SLAVEOF NO ONE
   → 通知其他 Slave 改為複製新 Master
   → 更新 Sentinel 的設定
```

### Sentinel vs Cluster

| 比較 | Sentinel | Cluster |
|:-----|:-----|:-----|
| 資料分片 | 不支援（單一資料集） | 支援（16384 Hash Slot） |
| 擴展方式 | 垂直擴展（升級機器） | 水平擴展（加節點） |
| 故障轉移 | Sentinel 投票 | Master 之間投票 |
| 適用場景 | 資料量 < 單機記憶體 | 資料量 > 單機記憶體 |
| 複雜度 | 簡單 | 較複雜（跨 slot 操作限制） |

### Cluster 架構

#### 資料分片 — Hash Slot

```
┌────────────────────────────────────────────┐
│          16384 個 Hash Slot                 │
│                                            │
│  Node A: Slot 0 ~ 5460                     │
│  Node B: Slot 5461 ~ 10922                 │
│  Node C: Slot 10923 ~ 16383               │
│                                            │
│  定位公式: SLOT = CRC16(key) % 16384       │
└────────────────────────────────────────────┘
```

```
Client                     Cluster
  │                          │
  │── SET user:1 "Jack" ──→  Node A
  │                          │ CRC16("user:1") % 16384 = 9189
  │                          │ Slot 9189 屬於 Node B
  │  ←── MOVED 9189 NodeB ──│
  │                          │
  │── SET user:1 "Jack" ──→  Node B  ✓
```

#### 主從複製與故障轉移

```
┌─────────┐     ┌─────────┐     ┌─────────┐
│ Master A │     │ Master B │     │ Master C │
│ 0~5460  │     │5461~10922│     │10923~16383│
└────┬────┘     └────┬────┘     └────┬────┘
     │               │               │
┌────┴────┐     ┌────┴────┐     ┌────┴────┐
│ Slave A │     │ Slave B │     │ Slave C │
└─────────┘     └─────────┘     └─────────┘
```

**故障轉移流程**：
1. 節點之間透過 Gossip 協議定期交換心跳
2. 節點超過 `cluster-node-timeout` 未回應 → 標記為 `PFAIL`
3. 超過半數 Master 認為該節點 `PFAIL` → 升級為 `FAIL`
4. 故障 Master 的 Slave 發起選舉，獲得多數票後晉升為新 Master
5. 新 Master 接管原 Slot，廣播更新

---

## 七、常見應用場景

### 分散式鎖

```go
// 加鎖：SET NX + EX（原子操作）
result := rdb.SetNX(ctx, "lock:order:123", "owner-uuid", 30*time.Second)

// 解鎖：Lua Script 確保原子性（先檢查再刪除）
unlockScript := redis.NewScript(`
    if redis.call("GET", KEYS[1]) == ARGV[1] then
        return redis.call("DEL", KEYS[1])
    else
        return 0
    end
`)
```

> **重點**：解鎖時必須用 Lua Script 保證「檢查 + 刪除」的原子性。如果分兩步做，可能在檢查後、刪除前鎖已過期被別人拿走，導致誤刪別人的鎖。
{: .important }

### 樂觀鎖 — WATCH / MULTI / EXEC

Redis 透過 `WATCH` 實現 CAS (Check-And-Set) 樂觀鎖：

```
WATCH 的原理：
  1. WATCH key     → 監視 key，記錄當前版本
  2. 讀取 key 的值   → 在應用層做業務判斷
  3. MULTI          → 開始交易
  4. 寫入命令        → 排入佇列（尚未執行）
  5. EXEC           → 提交交易
     → 如果 key 在 WATCH 後被其他 client 修改 → 回傳 nil（交易失敗）
     → 如果 key 沒被修改 → 正常執行所有命令
```

```
時間軸範例：

Client A                          Client B
   │                                 │
   │── WATCH balance ──→             │
   │── GET balance → 100             │
   │                                 │
   │   （計算：100 - 30 = 70）        │── SET balance 50 ──→ ✓
   │                                 │  （balance 被改了！）
   │── MULTI ──→                     │
   │── SET balance 70 ──→ (排隊)     │
   │── EXEC ──→ nil ❌ 交易失敗！     │
   │                                 │
   │  （偵測到 balance 被改過，放棄）   │
   │  （重新 WATCH → 重試整個流程）    │
```

**Go 實作**：

```go
func DeductBalance(ctx context.Context, rdb *redis.Client, userKey string, amount int) error {
    maxRetries := 5

    for i := 0; i < maxRetries; i++ {
        err := rdb.Watch(ctx, func(tx *redis.Tx) error {
            balance, err := tx.Get(ctx, userKey).Int()
            if err != nil {
                return err
            }
            if balance < amount {
                return fmt.Errorf("餘額不足：%d < %d", balance, amount)
            }

            _, err = tx.TxPipelined(ctx, func(pipe redis.Pipeliner) error {
                pipe.Set(ctx, userKey, balance-amount, 0)
                return nil
            })
            return err
        }, userKey)

        if err == nil {
            return nil
        }
        if err == redis.TxFailedErr {
            continue
        }
        return err
    }

    return fmt.Errorf("樂觀鎖重試 %d 次仍失敗", maxRetries)
}
```

> **重點**：`WATCH` 監視的粒度是整個 key。只要 key 的值有任何變動（即使改回原值），EXEC 都會失敗。這和資料庫 version 欄位樂觀鎖的差別 — 資料庫比對「值是否相同」，Redis 比對「有沒有被寫過」。
{: .note }

### Redis vs DB 樂觀鎖對比

| 比較 | Redis WATCH | DB Version 欄位 |
|:-----|:-----|:-----|
| 檢測機制 | key 有沒有被寫過（任何修改） | version 值是否相同 |
| ABA 問題 | 無（偵測的是「寫入動作」） | Version 方式無；值比對方式有 |
| 原子性保證 | MULTI/EXEC 批次原子 | 單條 UPDATE 天然原子 |
| 持久性 | 依持久化設定（可能丟失） | WAL 保證不丟失 |
| 效能 | 微秒級（記憶體操作） | 毫秒級（磁碟 I/O） |
| 適用場景 | 快取計數器、限流、搶購 | 訂單、庫存、帳務 |

### 快取穿透、擊穿、雪崩

```
┌────────────────────────────────────────────────┐
│ 快取穿透 (Cache Penetration)                    │
│ 問題：查詢不存在的 key，每次都打到 DB           │
│ 解法：布隆過濾器 / 快取空值                     │
├────────────────────────────────────────────────┤
│ 快取擊穿 (Cache Breakdown / Hotspot Invalid)   │
│ 問題：熱點 key 過期瞬間，大量請求打到 DB        │
│ 解法：互斥鎖重建 / 永不過期 + 非同步更新        │
├────────────────────────────────────────────────┤
│ 快取雪崩 (Cache Avalanche)                     │
│ 問題：大量 key 同時過期，DB 瞬間被壓垮         │
│ 解法：過期時間加隨機值 / 多級快取 / 限流降級    │
└────────────────────────────────────────────────┘
```

### 限流演算法

#### 固定窗口計數器

```
視窗: 每分鐘 100 次

  00:00 ─── 00:59 │ 01:00 ─── 01:59
  [count: 78]      │ [count: 0]
                   │
                   重置計數器

問題：00:50 發了 100 次 + 01:10 發了 100 次
     → 在 00:50~01:10 這 20 秒內有 200 次請求（超過限制）
```

#### 滑動窗口

```
用 Sorted Set 實作滑動窗口限流：

  ZADD rate:{ip} {timestamp} {unique_id}
  ZREMRANGEBYSCORE rate:{ip} 0 {now - window}
  ZCARD rate:{ip} → 當前窗口內的請求數
```

```go
func SlidingWindowRateLimit(ctx context.Context, rdb *redis.Client, key string, limit int, window time.Duration) (bool, error) {
    now := time.Now().UnixMilli()
    windowStart := now - window.Milliseconds()

    pipe := rdb.Pipeline()
    // 移除窗口外的舊記錄
    pipe.ZRemRangeByScore(ctx, key, "0", fmt.Sprintf("%d", windowStart))
    // 計算當前窗口內的請求數
    countCmd := pipe.ZCard(ctx, key)
    pipe.Exec(ctx)

    if countCmd.Val() >= int64(limit) {
        return false, nil // 超過限制
    }

    // 加入新請求
    pipe = rdb.Pipeline()
    pipe.ZAdd(ctx, key, redis.Z{Score: float64(now), Member: fmt.Sprintf("%d", now)})
    pipe.Expire(ctx, key, window) // 設定過期防止記憶體洩漏
    pipe.Exec(ctx)

    return true, nil
}
```

#### 令牌桶 (Token Bucket)

```
┌──────────────┐
│  Token Bucket │
│  容量: 10     │
│  ┌─────────┐ │    取得 token → 放行
│  │●●●●●●●  │ │ ──────────────→
│  └─────────┘ │    沒有 token → 拒絕
│              │
│  每秒補充 5 個│
└──────────────┘

特點：
  - 允許突發流量（桶裡有 token 就放行）
  - 長期速率穩定（補充速率固定）
  - 比固定窗口更平滑
```

```go
// Lua Script 實作令牌桶（原子操作）
var tokenBucketScript = redis.NewScript(`
    local key = KEYS[1]
    local capacity = tonumber(ARGV[1])    -- 桶容量
    local rate = tonumber(ARGV[2])        -- 每秒補充數
    local now = tonumber(ARGV[3])         -- 當前時間戳 (ms)
    local requested = tonumber(ARGV[4])   -- 請求的 token 數

    local data = redis.call("HMGET", key, "tokens", "last_time")
    local tokens = tonumber(data[1]) or capacity
    local last_time = tonumber(data[2]) or now

    -- 計算該補充多少 token
    local elapsed = (now - last_time) / 1000
    tokens = math.min(capacity, tokens + elapsed * rate)

    if tokens >= requested then
        tokens = tokens - requested
        redis.call("HMSET", key, "tokens", tokens, "last_time", now)
        redis.call("EXPIRE", key, capacity / rate * 2)
        return 1  -- 允許
    end

    redis.call("HMSET", key, "tokens", tokens, "last_time", now)
    redis.call("EXPIRE", key, capacity / rate * 2)
    return 0  -- 拒絕
`)
```

| 演算法 | 突發流量 | 精確度 | 實作複雜度 | 記憶體 |
|:-----|:-----|:-----|:-----|:-----|
| 固定窗口 | 窗口邊界突發 | 低 | 簡單 | O(1) |
| 滑動窗口 | 平滑 | 高 | 中等 | O(n) |
| 令牌桶 | 允許短暫突發 | 高 | 中等 | O(1) |

---

## 八、Redis 的 ACID 特性

| ACID | Redis 的體現 |
|:-----|:-----|
| **A (原子性)** | 單命令天然原子；多命令用 MULTI/EXEC 或 Lua Script |
| **C (一致性)** | 無 schema 約束，一致性由應用層保證 |
| **I (隔離性)** | 單執行緒 = 天然序列化隔離（Serializable） |
| **D (持久性)** | 取決於持久化設定：RDB / AOF / 混合模式 |

> **重點**：Redis 的 MULTI/EXEC 不是真正的 ACID 交易 — 它不支援 ROLLBACK。如果中間某個命令執行失敗，之前的命令不會回滾。它保證的是**批次命令的原子執行**（不會被其他命令插隊），而非傳統資料庫的交易語義。
{: .important }

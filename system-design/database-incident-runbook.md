# Database Incident Runbook

DB 爆炸時的排查手冊，依症狀分類，快速定位問題並處理。

---

## 1. CPU 飆升

**常見原因：** slow query 吃滿 CPU

### PostgreSQL

```sql
-- 找出執行最久的 active query
SELECT pid, now() - query_start AS duration, state, query
FROM pg_stat_activity
WHERE state = 'active'
ORDER BY duration DESC
LIMIT 10;
```

**處理步驟：**
1. 確認 `state = 'active'` 的 slow query
2. 先溫和取消：`SELECT pg_cancel_backend(pid);`
3. 無效再強制終止：`SELECT pg_terminate_backend(pid);`
4. 事後用 `EXPLAIN ANALYZE` 分析該 query，補 index 或改寫

### MySQL

```sql
-- 找出執行最久的 query
SELECT id, time, state, info
FROM information_schema.processlist
WHERE command = 'Query'
ORDER BY time DESC
LIMIT 10;
```

**處理步驟：**
1. 確認 `command = 'Query'` 且 `time` 長的連線
2. 先取消 query：`KILL QUERY <id>;`
3. 無效再斷連線：`KILL CONNECTION <id>;`
4. 事後用 `EXPLAIN` 分析並優化

---

## 2. 連線數暴增

**前置確認：** 先排除 connection pool 設定錯誤（max pool size 突然變大、新部署改了設定等）

### PostgreSQL

```sql
-- 各 state 的連線數分佈
SELECT state, count(*)
FROM pg_stat_activity
GROUP BY state
ORDER BY count DESC;
```

| 現象 | 原因 | 處理 |
|------|------|------|
| `idle in transaction` 佔多數 | transaction 長時間持有 lock 未 commit/rollback | 找出對應 query，確認是否能安全 cancel；檢查程式碼是否有 tx 未關閉 |
| `active` 佔多數且 duration 長 | slow query 堆積，連線無法釋放 | 同 CPU 飆升處理流程 |
| `idle` 佔多數 | connection pool 開太大或連線 leak | 調整 pool size；檢查程式碼是否有連線未歸還 |

### MySQL

```sql
-- 各 command 的連線數分佈
SELECT command, count(*)
FROM information_schema.processlist
GROUP BY command
ORDER BY count(*) DESC;

-- 確認是否有長時間未 commit 的 transaction
SELECT trx_id, trx_state, trx_started, trx_query
FROM information_schema.innodb_trx
ORDER BY trx_started ASC;
```

| 現象 | 原因 | 處理 |
|------|------|------|
| `Sleep` + `trx_state = 'RUNNING'`，`trx_started` 很早 | transaction 長時間持有 lock | 找出對應 trx，確認能否安全 kill |
| `Query` 佔多數且 `time` 長 | slow query 堆積 | 同 CPU 飆升處理流程 |
| `Sleep` 佔多數 | connection pool 開太大或連線 leak | 調整 pool size；檢查連線管理 |

---

## 3. Lock 等待 / Deadlock

### PostgreSQL

```sql
-- 查看誰在等誰的 lock
SELECT
    blocked.pid AS blocked_pid,
    blocked.query AS blocked_query,
    blocking.pid AS blocking_pid,
    blocking.query AS blocking_query
FROM pg_stat_activity blocked
JOIN pg_locks bl ON bl.pid = blocked.pid
JOIN pg_locks kl ON kl.locktype = bl.locktype
    AND kl.relation = bl.relation
    AND kl.pid != bl.pid
JOIN pg_stat_activity blocking ON blocking.pid = kl.pid
WHERE NOT bl.granted;
```

### MySQL

```sql
-- 查看 lock 等待
SELECT * FROM information_schema.innodb_lock_waits;

-- 查看最近 deadlock 資訊
SHOW ENGINE INNODB STATUS;  -- 找 LATEST DETECTED DEADLOCK 段落
```

**處理：** 找到 blocking transaction → 確認能否安全終止 → kill 後檢查程式碼 lock 順序

---

## 4. Replication Lag

**症狀：** 讀寫分離架構下，讀到舊資料

### PostgreSQL

```sql
-- 在 replica 上查看 lag
SELECT now() - pg_last_xact_replay_timestamp() AS replication_lag;
```

### MySQL

```sql
-- 在 replica 上查看 lag
SHOW SLAVE STATUS\G  -- 看 Seconds_Behind_Master
```

**常見原因：**
- replica 規格不足，追不上 write 量
- 大量 DDL 或大 transaction 卡住 replay
- 網路延遲

---

## 5. 線上 Schema 變更（不鎖表）

需要在線上修改 schema 時，避免鎖表造成服務中斷。

### 新增欄位

| DB | 做法 |
|----|------|
| PostgreSQL 11+ | `ADD COLUMN` 不論有無 `DEFAULT` 都不鎖表 |
| PostgreSQL 10- | `ADD COLUMN` 有 `DEFAULT` 會鎖表，無 `DEFAULT` 不鎖表 |
| MySQL | 加上 `ALGORITHM=INPLACE, LOCK=NONE` |

### 新增 Index

| DB | 做法 |
|----|------|
| PostgreSQL | `CREATE INDEX CONCURRENTLY` |
| MySQL | `ALTER TABLE ... ADD INDEX ... ALGORITHM=INPLACE, LOCK=NONE` |

---

## 6. 資料表拆分（Online Migration）

線上不停機拆分資料表的標準流程：

1. **建新表** — 設計好新的 schema
2. **雙寫** — 現有邏輯同時寫入新舊表，失敗只記 log 不拋錯
3. **回填** — 把歷史資料搬到新表，搬完做資料一致性驗證
4. **切讀** — 透過 feature flag 將讀取切換到新表
5. **清理** — 確認穩定後移除雙寫邏輯，刪除舊表/欄位

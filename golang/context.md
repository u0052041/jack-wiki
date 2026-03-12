---
layout: default
title: Context 並發控制完全指南
parent: Golang 筆記
nav_order: 9
---

# Go 進階筆記：Context 並發控制完全指南
{: .no_toc }

取消信號、超時控制與跨層傳值
{: .fs-6 .fw-300 }

## 目錄
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## 一、Context 的本質

### context 是 Interface

```go
type Context interface {
    Deadline() (deadline time.Time, ok bool)  // 回傳截止時間
    Done() <-chan struct{}                     // 回傳取消信號的 channel
    Err() error                               // 回傳取消原因
    Value(key any) any                        // 取得附帶的值
}
```

**核心觀念**：Context 是 Go 並發控制的標準機制，用來在 Goroutine 之間傳遞「取消信號」、「超時期限」與「請求範圍的值」。

> **重點**：Context 解決的核心問題 — 當你啟動多個 Goroutine 處理一個請求時，如何在請求結束或超時時，通知所有 Goroutine 停止工作、釋放資源？
{: .note }

### 為什麼需要 Context？

```go
// 沒有 Context 的問題：Goroutine 洩漏
func fetchAll(urls []string) []string {
    results := make([]string, len(urls))
    for i, url := range urls {
        go func(i int, url string) {
            results[i] = fetch(url)  // 如果使用者取消請求，這些 Goroutine 還在跑！
        }(i, url)
    }
    // 沒辦法通知 Goroutine 停止
    return results
}
```

> **嚴重**：Goroutine 洩漏 (Goroutine Leak) 是 Go 程式中最常見的記憶體洩漏來源之一。每個洩漏的 Goroutine 至少佔用 2KB~8KB 記憶體，且永遠不會被 GC 回收。
{: .important }

---

## 二、四種建立 Context 的方式

### 1. context.Background()

```go
ctx := context.Background()
```

- 回傳空的 Context，永遠不會被取消
- **用途**：作為整棵 Context Tree 的根節點
- **使用時機**：`main`、初始化、測試

### 2. context.TODO()

```go
ctx := context.TODO()
```

- 功能與 `Background()` 完全相同
- **用途**：佔位符，表示「我知道這裡應該傳 Context，但還不確定要用哪個」
- **使用時機**：重構過程中暫時使用

> **提示**：`Background()` 和 `TODO()` 的底層實作完全一樣，差別只在語義。用 `TODO()` 可以方便日後搜尋需要補上正確 Context 的地方。
{: .note }

### 3. context.WithCancel()

```go
ctx, cancel := context.WithCancel(parentCtx)
defer cancel()  // 必須呼叫！
```

- 回傳子 Context 和 `cancel` 函式
- 呼叫 `cancel()` 時，`ctx.Done()` 的 channel 會被關閉
- **用途**：手動控制取消

```go
func fetchWithCancel(ctx context.Context) (string, error) {
    ctx, cancel := context.WithCancel(ctx)
    defer cancel()

    ch := make(chan string, 1)
    go func() {
        ch <- slowOperation()
    }()

    select {
    case result := <-ch:
        return result, nil
    case <-ctx.Done():
        return "", ctx.Err()  // context canceled
    }
}
```

### 4. context.WithTimeout()

```go
ctx, cancel := context.WithTimeout(parentCtx, 5*time.Second)
defer cancel()  // 即使超時也必須呼叫！
```

- 指定時間長度後自動取消
- **用途**：API 呼叫、資料庫查詢的超時控制

```go
func callAPI(ctx context.Context) ([]byte, error) {
    ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
    defer cancel()

    req, err := http.NewRequestWithContext(ctx, "GET", "https://api.example.com/data", nil)
    if err != nil {
        return nil, fmt.Errorf("建立請求失敗: %w", err)
    }

    resp, err := http.DefaultClient.Do(req)
    if err != nil {
        return nil, fmt.Errorf("API 呼叫失敗: %w", err)
    }
    defer resp.Body.Close()

    return io.ReadAll(resp.Body)
}
```

### 5. context.WithDeadline()

```go
deadline := time.Now().Add(5 * time.Second)
ctx, cancel := context.WithDeadline(parentCtx, deadline)
defer cancel()
```

- 指定絕對時間點自動取消
- **用途**：需要在特定時間點前完成的操作

> **提示**：`WithTimeout(ctx, 5*time.Second)` 等價於 `WithDeadline(ctx, time.Now().Add(5*time.Second))`。一般優先使用 `WithTimeout`，語義更清楚。
{: .note }

### 6. context.WithValue()

```go
ctx := context.WithValue(parentCtx, key, value)
```

- 附帶 key-value 資料到 Context 中
- **用途**：傳遞請求範圍的資料 (Request-Scoped Data)

```go
// 定義 key 類型 (避免碰撞)
type contextKey string

const (
    userIDKey    contextKey = "userID"
    requestIDKey contextKey = "requestID"
)

// 設定值
ctx := context.WithValue(r.Context(), userIDKey, "user-123")
ctx = context.WithValue(ctx, requestIDKey, "req-abc")

// 取得值
userID := ctx.Value(userIDKey).(string)
```

> **注意**：key 必須使用自定義類型，不要用 `string` 或 `int` 等內建類型，否則不同 package 之間會發生 key 碰撞。
{: .warning }

---

## 三、Context Tree：父子關係

### 取消傳播機制

```
Background (根)
├── WithCancel (A)
│   ├── WithTimeout (B) ← 取消 A 時，B 也會被取消
│   └── WithValue (C)   ← 取消 A 時，C 也會被取消
└── WithTimeout (D)     ← 取消 A 不影響 D
```

**規則**：
- 父 Context 被取消 → 所有子 Context 自動取消
- 子 Context 被取消 → 不影響父 Context
- 子 Context 的超時不能超過父 Context

```go
// 父 Context 3 秒超時
parentCtx, parentCancel := context.WithTimeout(context.Background(), 3*time.Second)
defer parentCancel()

// 子 Context 想要 10 秒超時，但實際只有 3 秒 (受限於父)
childCtx, childCancel := context.WithTimeout(parentCtx, 10*time.Second)
defer childCancel()

deadline, _ := childCtx.Deadline()
// deadline 會是 3 秒後，不是 10 秒後
```

> **重點**：子 Context 的超時不能「延長」父 Context 的期限，只能「縮短」。這是 Context 樹的核心安全機制。
{: .note }

---

## 四、實戰模式

### 模式 1：HTTP Server 超時控制

```go
func handler(w http.ResponseWriter, r *http.Request) {
    // r.Context() 在客戶端斷線時自動取消
    ctx := r.Context()

    result := make(chan string, 1)
    go func() {
        result <- expensiveQuery(ctx)
    }()

    select {
    case res := <-result:
        fmt.Fprint(w, res)
    case <-ctx.Done():
        // 客戶端已斷線或 server 超時
        http.Error(w, "請求已取消", http.StatusServiceUnavailable)
    }
}

// Server 層級的超時設定
srv := &http.Server{
    Addr:         ":8080",
    ReadTimeout:  5 * time.Second,
    WriteTimeout: 10 * time.Second,
}
```

### 模式 2：資料庫查詢超時

```go
func GetUser(ctx context.Context, id int) (*User, error) {
    ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
    defer cancel()

    var user User
    err := db.QueryRowContext(ctx,
        "SELECT id, name, email FROM users WHERE id = $1", id,
    ).Scan(&user.ID, &user.Name, &user.Email)

    if err != nil {
        if errors.Is(err, context.DeadlineExceeded) {
            return nil, fmt.Errorf("查詢使用者 %d 超時: %w", id, err)
        }
        return nil, fmt.Errorf("查詢使用者 %d 失敗: %w", id, err)
    }
    return &user, nil
}
```

### 模式 3：多個 Goroutine 協作取消

```go
func fetchMultiple(ctx context.Context, urls []string) ([]string, error) {
    ctx, cancel := context.WithCancel(ctx)
    defer cancel()

    results := make([]string, len(urls))
    errCh := make(chan error, len(urls))
    var wg sync.WaitGroup

    for i, url := range urls {
        wg.Add(1)
        go func(i int, url string) {
            defer wg.Done()

            req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
            if err != nil {
                errCh <- fmt.Errorf("建立請求 %s 失敗: %w", url, err)
                cancel()  // 任一失敗就取消其他所有
                return
            }

            resp, err := http.DefaultClient.Do(req)
            if err != nil {
                errCh <- fmt.Errorf("請求 %s 失敗: %w", url, err)
                cancel()
                return
            }
            defer resp.Body.Close()

            body, _ := io.ReadAll(resp.Body)
            results[i] = string(body)
        }(i, url)
    }

    wg.Wait()
    close(errCh)

    if err := <-errCh; err != nil {
        return nil, err
    }
    return results, nil
}
```

### 模式 4：errgroup 搭配 Context (推薦)

```go
import "golang.org/x/sync/errgroup"

func fetchAll(ctx context.Context, urls []string) ([]string, error) {
    g, ctx := errgroup.WithContext(ctx)
    results := make([]string, len(urls))

    for i, url := range urls {
        g.Go(func() error {
            req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
            if err != nil {
                return err
            }
            resp, err := http.DefaultClient.Do(req)
            if err != nil {
                return err
            }
            defer resp.Body.Close()

            body, err := io.ReadAll(resp.Body)
            if err != nil {
                return err
            }
            results[i] = string(body)
            return nil
        })
    }

    if err := g.Wait(); err != nil {
        return nil, err
    }
    return results, nil
}
```

> **提示**：`errgroup.WithContext` 是生產環境中最推薦的模式，它自動處理：任一 Goroutine 失敗就取消其他所有、收集第一個錯誤、等待所有 Goroutine 結束。
{: .note }

### 模式 5：Middleware 注入 Context 值

```go
// Middleware：從 Header 提取 Request ID
func RequestIDMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        requestID := r.Header.Get("X-Request-ID")
        if requestID == "" {
            requestID = uuid.New().String()
        }

        ctx := context.WithValue(r.Context(), requestIDKey, requestID)
        next.ServeHTTP(w, r.WithContext(ctx))
    })
}

// Middleware：從 JWT 提取使用者資訊
func AuthMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        token := r.Header.Get("Authorization")
        userID, err := validateToken(token)
        if err != nil {
            http.Error(w, "Unauthorized", 401)
            return
        }

        ctx := context.WithValue(r.Context(), userIDKey, userID)
        next.ServeHTTP(w, r.WithContext(ctx))
    })
}

// Handler 中取值
func userHandler(w http.ResponseWriter, r *http.Request) {
    userID, ok := r.Context().Value(userIDKey).(string)
    if !ok {
        http.Error(w, "missing user", 400)
        return
    }
    fmt.Fprintf(w, "Hello, %s", userID)
}
```

### 模式 6：Graceful Shutdown

```go
func main() {
    srv := &http.Server{Addr: ":8080", Handler: mux}

    // 啟動 Server
    go func() {
        if err := srv.ListenAndServe(); err != http.ErrServerClosed {
            log.Fatalf("Server 錯誤: %v", err)
        }
    }()

    // 等待中斷信號
    quit := make(chan os.Signal, 1)
    signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
    <-quit
    log.Println("正在關閉 Server...")

    // 給 30 秒的時間完成正在處理的請求
    ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
    defer cancel()

    if err := srv.Shutdown(ctx); err != nil {
        log.Fatalf("Server 強制關閉: %v", err)
    }
    log.Println("Server 已優雅關閉")
}
```

---

## 五、context.WithoutCancel (Go 1.21+)

```go
// 子 Context 不受父 Context 取消影響
ctx := context.WithoutCancel(parentCtx)
```

**使用場景**：HTTP 請求結束後，仍需繼續執行的背景任務 (如寫 audit log)。

```go
func handler(w http.ResponseWriter, r *http.Request) {
    // 即使 r.Context() 被取消 (客戶端斷線)，審計日誌仍需完成
    auditCtx := context.WithoutCancel(r.Context())

    go func() {
        // 給背景任務設定獨立的超時
        ctx, cancel := context.WithTimeout(auditCtx, 10*time.Second)
        defer cancel()
        writeAuditLog(ctx, "user accessed resource")
    }()

    fmt.Fprint(w, "OK")
}
```

> **注意**：`WithoutCancel` 仍會繼承父 Context 的 Value，只是不繼承取消信號。
{: .warning }

---

## 六、context.AfterFunc (Go 1.21+)

```go
stop := context.AfterFunc(ctx, func() {
    // Context 被取消時執行
    cleanup()
})
// 如果不再需要，可以呼叫 stop() 取消註冊
```

**使用場景**：Context 取消時自動執行清理邏輯。

```go
func watchResource(ctx context.Context, resource *Resource) {
    // Context 取消時自動釋放資源
    context.AfterFunc(ctx, func() {
        resource.Close()
        log.Println("資源已自動釋放")
    })

    // 正常業務邏輯...
}
```

---

## 七、避坑指南 (必讀)

### 1. 忘記呼叫 cancel — 資源洩漏

> **嚴重**：每個 `WithCancel`/`WithTimeout`/`WithDeadline` 都會建立內部 Goroutine 來監聽父 Context。不呼叫 `cancel()` 會導致這些 Goroutine 永遠不會釋放！
{: .important }

```go
// 錯誤寫法：忘記 cancel
func bad(ctx context.Context) error {
    ctx, _ = context.WithTimeout(ctx, 5*time.Second)  // 洩漏！
    return doWork(ctx)
}

// 正確寫法：defer cancel()
func good(ctx context.Context) error {
    ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
    defer cancel()  // 永遠要 defer cancel！
    return doWork(ctx)
}
```

### 2. 把 Context 存進 Struct

```go
// 錯誤寫法：Context 不應該存進 struct
type Service struct {
    ctx context.Context  // 這是反模式！
    db  *sql.DB
}

// 正確寫法：Context 作為函式第一個參數傳入
type Service struct {
    db *sql.DB
}

func (s *Service) GetUser(ctx context.Context, id int) (*User, error) {
    return s.db.QueryRowContext(ctx, "SELECT ...", id)
}
```

> **原則**：Context 是「請求範圍」的，每個請求都有自己的 Context。存進 struct 會導致 Context 被錯誤共用。
{: .warning }

### 3. 用 WithValue 傳遞業務參數

```go
// 錯誤寫法：把業務參數塞進 Context
ctx = context.WithValue(ctx, "userID", 123)
ctx = context.WithValue(ctx, "page", 1)
ctx = context.WithValue(ctx, "limit", 20)

func ListUsers(ctx context.Context) []User {
    page := ctx.Value("page").(int)      // 沒有型別安全、容易 panic
    limit := ctx.Value("limit").(int)
    // ...
}

// 正確寫法：業務參數用函式參數明確傳遞
func ListUsers(ctx context.Context, page, limit int) []User {
    // ctx 只用來傳遞取消信號和請求範圍的 metadata
}
```

**WithValue 適合傳遞的資料**：

| 適合 | 不適合 |
|:-----|:-----|
| Request ID | 分頁參數 |
| User ID (認證後) | 查詢條件 |
| Trace ID | 業務邏輯數據 |
| Locale/Language | 設定值 |

### 4. 傳遞 nil Context

```go
// 錯誤寫法：傳 nil
func bad() {
    doWork(nil)  // panic: nil Context
}

// 正確寫法：不確定時用 context.TODO()
func good() {
    doWork(context.TODO())
}
```

### 5. 用字串當 WithValue 的 Key

```go
// 錯誤寫法：string 當 key
ctx = context.WithValue(ctx, "userID", "123")  // 任何 package 都可能覆蓋

// 正確寫法：自定義未導出類型
type contextKey string
const userIDKey contextKey = "userID"

// 更安全的寫法：用空 struct
type userIDKeyType struct{}
var userIDKey = userIDKeyType{}
ctx = context.WithValue(ctx, userIDKey, "123")
```

### 6. 誤解 Done() channel 的行為

```go
// 錯誤理解：Done() 在建立時就可以讀取
ctx := context.Background()
<-ctx.Done()  // 永遠阻塞！Background 永遠不會取消

// 正確理解
ctx, cancel := context.WithCancel(context.Background())
go func() {
    time.Sleep(time.Second)
    cancel()  // 1 秒後取消
}()
<-ctx.Done()  // 阻塞直到被取消
fmt.Println(ctx.Err())  // context canceled
```

---

## 八、Context 與標準庫整合

### 支援 Context 的標準庫 API

| Package | 方法 | 說明 |
|:-----|:-----|:-----|
| `net/http` | `http.NewRequestWithContext` | 建立帶 Context 的 HTTP 請求 |
| `net/http` | `(*Request).Context()` | 取得請求的 Context |
| `database/sql` | `db.QueryContext` | 帶超時的 DB 查詢 |
| `database/sql` | `db.ExecContext` | 帶超時的 DB 寫入 |
| `os/exec` | `exec.CommandContext` | 帶超時的外部命令 |
| `net` | `net.Dialer.DialContext` | 帶超時的網路連線 |

```go
// HTTP 請求
req, _ := http.NewRequestWithContext(ctx, "GET", url, nil)
resp, err := client.Do(req)

// DB 查詢
rows, err := db.QueryContext(ctx, "SELECT * FROM users")

// 外部命令
cmd := exec.CommandContext(ctx, "ffmpeg", "-i", input, output)
err := cmd.Run()
```

---

## 九、Err() 回傳值解析

```go
ctx, cancel := context.WithTimeout(context.Background(), time.Second)
defer cancel()
```

| 情境 | `ctx.Err()` 回傳值 | 說明 |
|:-----|:-----|:-----|
| 尚未取消 | `nil` | Context 仍然有效 |
| 手動呼叫 `cancel()` | `context.Canceled` | 主動取消 |
| 超過 Deadline | `context.DeadlineExceeded` | 超時取消 |

```go
select {
case <-ctx.Done():
    switch ctx.Err() {
    case context.Canceled:
        log.Println("請求被取消")
    case context.DeadlineExceeded:
        log.Println("請求超時")
    }
}
```

> **提示**：使用 `errors.Is(err, context.Canceled)` 或 `errors.Is(err, context.DeadlineExceeded)` 判斷，因為錯誤可能被包裝過。
{: .note }

---

## 十、效能考量

### WithValue 的查找複雜度

```go
// WithValue 是鏈表結構，查找是 O(n)
ctx := context.Background()
ctx = context.WithValue(ctx, key1, val1)  // 第 1 層
ctx = context.WithValue(ctx, key2, val2)  // 第 2 層
ctx = context.WithValue(ctx, key3, val3)  // 第 3 層

ctx.Value(key1)  // 需要遍歷 3 層才找到
```

| 層數 | 查找效能 | 建議 |
|:-----|:-----|:-----|
| 1~5 層 | 可忽略 | 正常使用 |
| 5~10 層 | 輕微影響 | 考慮合併為 struct |
| 10+ 層 | 明顯影響 | 必須合併為 struct |

**優化方式**：將多個值合併為一個 struct

```go
// 不好：多層 WithValue
ctx = context.WithValue(ctx, requestIDKey, reqID)
ctx = context.WithValue(ctx, userIDKey, userID)
ctx = context.WithValue(ctx, traceIDKey, traceID)

// 更好：合併為一個 struct
type RequestMeta struct {
    RequestID string
    UserID    string
    TraceID   string
}

ctx = context.WithValue(ctx, requestMetaKey, &RequestMeta{
    RequestID: reqID,
    UserID:    userID,
    TraceID:   traceID,
})
```

---

## 十一、完整實戰範例

### 生產等級的 HTTP Service

```go
package main

import (
    "context"
    "encoding/json"
    "errors"
    "fmt"
    "log"
    "net/http"
    "os"
    "os/signal"
    "syscall"
    "time"
)

type contextKey string

const requestIDKey contextKey = "requestID"

// Middleware: 注入 Request ID + 設定超時
func requestMiddleware(timeout time.Duration) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            // 注入 Request ID
            reqID := r.Header.Get("X-Request-ID")
            if reqID == "" {
                reqID = fmt.Sprintf("req-%d", time.Now().UnixNano())
            }

            // 設定請求超時
            ctx, cancel := context.WithTimeout(r.Context(), timeout)
            defer cancel()

            ctx = context.WithValue(ctx, requestIDKey, reqID)
            w.Header().Set("X-Request-ID", reqID)

            next.ServeHTTP(w, r.WithContext(ctx))
        })
    }
}

// Handler
func userHandler(w http.ResponseWriter, r *http.Request) {
    ctx := r.Context()
    reqID, _ := ctx.Value(requestIDKey).(string)

    log.Printf("[%s] 開始處理使用者請求", reqID)

    user, err := fetchUser(ctx, 123)
    if err != nil {
        if errors.Is(err, context.DeadlineExceeded) {
            log.Printf("[%s] 請求超時", reqID)
            http.Error(w, "Request Timeout", 408)
            return
        }
        log.Printf("[%s] 查詢失敗: %v", reqID, err)
        http.Error(w, "Internal Error", 500)
        return
    }

    json.NewEncoder(w).Encode(user)
}

func fetchUser(ctx context.Context, id int) (*User, error) {
    // 設定 DB 查詢的獨立超時 (不超過父 Context)
    ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
    defer cancel()

    // 模擬 DB 查詢
    select {
    case <-time.After(100 * time.Millisecond):
        return &User{ID: id, Name: "Alice"}, nil
    case <-ctx.Done():
        return nil, fmt.Errorf("fetchUser: %w", ctx.Err())
    }
}

type User struct {
    ID   int    `json:"id"`
    Name string `json:"name"`
}

func main() {
    mux := http.NewServeMux()
    mux.HandleFunc("/user", userHandler)

    // 套用 Middleware：每個請求最多 10 秒
    handler := requestMiddleware(10 * time.Second)(mux)

    srv := &http.Server{
        Addr:    ":8080",
        Handler: handler,
    }

    // 啟動 Server
    go func() {
        log.Println("Server 啟動於 :8080")
        if err := srv.ListenAndServe(); err != http.ErrServerClosed {
            log.Fatalf("Server 錯誤: %v", err)
        }
    }()

    // Graceful Shutdown
    quit := make(chan os.Signal, 1)
    signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
    <-quit

    log.Println("正在關閉 Server...")
    ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
    defer cancel()

    if err := srv.Shutdown(ctx); err != nil {
        log.Fatalf("強制關閉: %v", err)
    }
    log.Println("Server 已優雅關閉")
}
```

---

## 十二、常見面試題

### Q1：context.Background() 和 context.TODO() 的差別？
- 功能完全相同，都是空 Context
- `Background()` 用於程式入口 (main/init/test)
- `TODO()` 用於暫時不確定要用哪個 Context 的場合

### Q2：為什麼每次都要 defer cancel()？
- `WithCancel`/`WithTimeout`/`WithDeadline` 會在內部建立監聽 Goroutine
- 不呼叫 `cancel()` 會導致這些 Goroutine 洩漏，直到父 Context 被取消
- `defer cancel()` 確保函式結束時一定釋放資源
- 即使 Context 已經自動超時取消，呼叫 `cancel()` 仍然是安全的 (冪等操作)

### Q3：WithValue 的 key 為什麼要用自定義類型？
- 使用 `string` 或 `int` 作為 key，不同 package 可能用到相同的 key 值
- 自定義未導出類型 (unexported type) 確保只有定義該類型的 package 能存取對應的值
- 這是 Go 的慣例，防止命名空間污染

### Q4：Context 取消是同步還是非同步的？
- **非同步**。呼叫 `cancel()` 後，子 Goroutine 不會立即停止
- 子 Goroutine 需要自己監聽 `ctx.Done()` 並主動退出
- 這是「協作式取消」(Cooperative Cancellation)，不是強制終止

```go
// 子 Goroutine 必須自己配合
func worker(ctx context.Context) {
    for {
        select {
        case <-ctx.Done():
            fmt.Println("收到取消信號，退出")
            return  // 主動退出
        default:
            doWork()
        }
    }
}
```

### Q5：以下程式碼有什麼問題？

```go
func handler(w http.ResponseWriter, r *http.Request) {
    go func() {
        time.Sleep(time.Second)
        // 使用 r.Context() 去做 DB 查詢
        db.QueryContext(r.Context(), "INSERT INTO logs ...")
    }()
    w.Write([]byte("OK"))
}
```

**問題**：`handler` 回傳後 `r.Context()` 可能已被取消，背景 Goroutine 的 DB 查詢會失敗。

**解法**：使用 `context.WithoutCancel(r.Context())` (Go 1.21+) 或建立獨立的 `context.Background()` 搭配自己的超時。

---

## 十三、最佳實踐總結

### Do's (建議做法)

| 實踐 | 說明 |
|:-----|:-----|
| Context 作為第一個參數 | 函式簽名 `func Foo(ctx context.Context, ...)` |
| 永遠 defer cancel() | 避免 Goroutine 洩漏 |
| 向下傳遞 Context | 每個函式接收上層的 Context 繼續傳遞 |
| 監聽 ctx.Done() | 長時間操作要配合取消信號 |
| 使用自定義 key 類型 | 避免 WithValue 的 key 碰撞 |
| 設定合理的超時 | 避免請求無限等待 |

### Don'ts (避免做法)

| 避免 | 原因 |
|:-----|:-----|
| 把 Context 存進 struct | Context 是請求範圍的，不應被共用 |
| 傳 nil Context | 會導致 panic，用 `context.TODO()` 代替 |
| 用 WithValue 傳業務參數 | WithValue 用於 metadata，業務參數用函式參數 |
| 忽略 cancel 回傳值 | 必須呼叫 cancel 避免洩漏 |
| 用字串當 Value key | 不同 package 會碰撞 |
| 過度嵌套 WithValue | O(n) 查找，效能會下降 |

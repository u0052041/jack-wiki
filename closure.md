---
layout: default
title: 閉包核心與實戰
nav_order: 5
---

# Golang 閉包 (Closure) 核心與實戰
{: .no_toc }

狀態隔離、常見陷阱與業界應用
{: .fs-6 .fw-300 }

## 目錄
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## 1. 核心觀念

**定義**：函式 + 該函式引用的外部變數 (Captured Environment)

**底層機制**：被捕獲的變數會經過逃逸分析 (Escape Analysis)，從 Stack 搬移到 Heap，確保函式執行完後變數依然存在且狀態獨立。

```go
func outer() func() int {
    count := 0  // 這個變數會被「捕獲」
    return func() int {
        count++  // 閉包內可以存取並修改外部變數
        return count
    }
}
```

> **重點**：閉包捕獲的是變數的「參考」(reference)，不是「值」(value)。這是很多陷阱的根源。
{: .note }

---

## 2. 簡單範例：狀態隔離 (Counter)

**目的**：取代全域變數，確保每個計數器互相獨立。

```go
func NewCounter() func() int {
    i := 0  // 私有變數 (被藏起來)
    return func() int {
        i++
        return i
    }
}

// 使用範例
c1 := NewCounter()
c1()  // -> 1
c1()  // -> 2

c2 := NewCounter()
c2()  // -> 1 (與 c1 互不影響)
```

---

## 3. 實戰範例：Middleware / 工廠模式

**場景**：在 Web Framework (如 Gin/Echo) 中，用閉包鎖定 Config 或權限設定。

```go
// 工廠：鎖定 "targetRole"
func RequireRole(targetRole string) func(User) bool {
    return func(u User) bool {
        // 閉包捕獲了 targetRole
        return u.Role == targetRole
    }
}

// 實戰：建立專用檢查器
checkAdmin := RequireRole("admin")
checkEditor := RequireRole("editor")

if checkAdmin(currentUser) {
    // 執行管理員操作
}
```

---

## 4. 常見陷阱 (必讀)

### 陷阱 1：迴圈變數捕獲 (最常見！)

> **嚴重**：這是 Go 最臭名昭著的陷阱，幾乎每個 Go 開發者都踩過！
{: .important }

```go
// 錯誤示範
funcs := []func(){}
for i := 0; i < 3; i++ {
    funcs = append(funcs, func() {
        fmt.Println(i)  // 捕獲的是同一個變數 i
    })
}

for _, f := range funcs {
    f()
}
// 輸出：3 3 3 (不是 0 1 2！)
```

**原因**：所有閉包都捕獲同一個變數 `i`，迴圈結束時 `i=3`。

**解法 1：傳參數**
```go
for i := 0; i < 3; i++ {
    funcs = append(funcs, func(n int) func() {
        return func() { fmt.Println(n) }
    }(i))  // 立即傳入 i 的「當前值」
}
```

**解法 2：區域變數**
```go
for i := 0; i < 3; i++ {
    i := i  // 建立區域副本 (shadowing)
    funcs = append(funcs, func() {
        fmt.Println(i)
    })
}
```

> **好消息**：Go 1.22+ 已修復此問題，迴圈變數會自動建立副本。但舊版程式碼仍需注意！
{: .note }

### 陷阱 2：Goroutine + 迴圈變數

```go
// 錯誤示範
for _, url := range urls {
    go func() {
        fetch(url)  // 所有 goroutine 可能都抓同一個 url！
    }()
}

// 正確寫法
for _, url := range urls {
    go func(u string) {
        fetch(u)
    }(url)  // 傳入當前值
}
```

### 陷阱 3：Defer + 閉包

```go
func process() {
    for i := 0; i < 3; i++ {
        defer func() {
            fmt.Println(i)  // 捕獲變數 i
        }()
    }
}
// 輸出：3 3 3 (LIFO 順序執行，但 i 都是 3)

// 正確寫法
func process() {
    for i := 0; i < 3; i++ {
        defer func(n int) {
            fmt.Println(n)
        }(i)  // 傳入當前值
    }
}
// 輸出：2 1 0 (LIFO)
```

### 陷阱 4：閉包修改外部變數

```go
func danger() []func() int {
    result := []func() int{}
    x := 0

    for i := 0; i < 3; i++ {
        result = append(result, func() int {
            x++  // 所有閉包共用同一個 x
            return x
        })
    }
    return result
}

funcs := danger()
fmt.Println(funcs[0]())  // 1
fmt.Println(funcs[1]())  // 2 (不是 1！)
fmt.Println(funcs[2]())  // 3
```

---

## 5. 更多實用範例

### 延遲計算 (Lazy Evaluation)

```go
func expensiveComputation() func() int {
    var result *int  // 尚未計算
    return func() int {
        if result == nil {
            r := heavyWork()  // 只在第一次呼叫時計算
            result = &r
        }
        return *result
    }
}

getValue := expensiveComputation()
// heavyWork 只會執行一次
getValue()  // 計算
getValue()  // 使用快取
getValue()  // 使用快取
```

### 函式選項模式 (Functional Options)

```go
type Server struct {
    host    string
    port    int
    timeout time.Duration
}

type Option func(*Server)

func WithPort(port int) Option {
    return func(s *Server) {
        s.port = port
    }
}

func WithTimeout(t time.Duration) Option {
    return func(s *Server) {
        s.timeout = t
    }
}

func NewServer(host string, opts ...Option) *Server {
    s := &Server{host: host, port: 8080}  // 預設值
    for _, opt := range opts {
        opt(s)
    }
    return s
}

// 使用
server := NewServer("localhost",
    WithPort(9000),
    WithTimeout(30*time.Second),
)
```

### 節流器 (Rate Limiter)

```go
func RateLimiter(interval time.Duration) func() bool {
    var lastCall time.Time
    var mu sync.Mutex

    return func() bool {
        mu.Lock()
        defer mu.Unlock()

        if time.Since(lastCall) < interval {
            return false  // 太快，拒絕
        }
        lastCall = time.Now()
        return true  // 允許
    }
}

limiter := RateLimiter(time.Second)
limiter()  // true
limiter()  // false (太快)
time.Sleep(time.Second)
limiter()  // true
```

---

## 6. 效能考量

### 閉包 vs 結構體方法

```go
// 閉包方式
func counterClosure() func() int {
    n := 0
    return func() int {
        n++
        return n
    }
}

// 結構體方式
type Counter struct {
    n int
}
func (c *Counter) Inc() int {
    c.n++
    return c.n
}
```

| 比較 | 閉包 | 結構體 |
|:-----|:-----|:-----|
| 記憶體 | 每次建立新的閉包物件 | 可重複使用 |
| 可讀性 | 簡潔，適合簡單場景 | 清晰，適合複雜狀態 |
| 測試 | 較難 mock | 容易 mock |
| 效能 | 略慢 (heap allocation) | 略快 |

> **建議**：簡單狀態用閉包，複雜邏輯用結構體。
{: .note }

---

## 7. 常見面試題

### Q1：什麼是閉包？
閉包是一個函式加上它所引用的外部變數。即使外部函式已經返回，閉包仍可存取這些變數。

### Q2：以下程式碼輸出什麼？

```go
for i := 0; i < 3; i++ {
    defer func() { fmt.Print(i) }()
}
```
**答案**：`333` — 所有 defer 的閉包都捕獲同一個變數 `i`，執行時 `i` 已經是 3。

### Q3：如何修復上題？
- 傳參數：`defer func(n int) { fmt.Print(n) }(i)`
- 區域變數：在迴圈內加 `i := i`

### Q4：閉包會導致記憶體洩漏嗎？
可能。如果閉包長期持有大物件的引用，該物件無法被 GC 回收。確保不需要的引用及時清空。

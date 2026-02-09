---
layout: default
title: Goroutine & Channel 並發全攻略
nav_order: 11
---

# Go 進階筆記：Goroutine & Channel 並發全攻略
{: .no_toc }

從排程原理到生產級並發模式
{: .fs-6 .fw-300 }

## 目錄
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## 一、Goroutine 的本質

### 什麼是 Goroutine？

Goroutine 是 Go runtime 管理的輕量級執行緒 (Green Thread)，由 Go 排程器 (Scheduler) 而非 OS 排程。

```go
// 啟動一個 Goroutine — 就是這麼簡單
go func() {
    fmt.Println("我在另一個 Goroutine 中執行")
}()
```

### Goroutine vs OS Thread

| 比較 | Goroutine | OS Thread |
|:-----|:-----|:-----|
| 初始 Stack | ~2KB (動態成長) | ~1MB (固定) |
| 建立成本 | 極低 (~幾百 ns) | 高 (~幾十 μs) |
| 排程 | Go runtime (User Space) | OS Kernel |
| 切換成本 | ~幾十 ns | ~幾 μs |
| 數量上限 | 輕鬆開到百萬 | 通常數千就吃力 |
| 通訊方式 | Channel (CSP 模型) | 共享記憶體 + Lock |

> **重點**：Go 的並發哲學 — "Don't communicate by sharing memory; share memory by communicating." 優先用 Channel 通訊，而非共享記憶體加鎖。
{: .note }

### GMP 排程模型

```
      G (Goroutine)     — 要執行的任務
      M (Machine/Thread) — OS 執行緒，實際執行程式碼
      P (Processor)      — 邏輯處理器，持有本地佇列

┌─────────────────────────────────────────────┐
│ Go Runtime Scheduler                        │
│                                             │
│   P0           P1           P2              │
│  ┌───┐       ┌───┐       ┌───┐             │
│  │ M │       │ M │       │ M │             │
│  └─┬─┘       └─┬─┘       └─┬─┘             │
│    │            │            │               │
│  [G G G]     [G G]       [G G G G]         │
│  Local Q     Local Q     Local Q            │
│                                             │
│  ─────── Global Run Queue ───────           │
│  [G] [G] [G]                                │
└─────────────────────────────────────────────┘
```

| 元素 | 說明 |
|:-----|:-----|
| **G** | Goroutine，包含執行的函式、Stack、狀態 |
| **M** | OS Thread，由 OS 管理 |
| **P** | 邏輯處理器，數量 = `GOMAXPROCS` (預設 = CPU 核心數) |

**排程流程**：
1. 新建的 G 放入當前 P 的本地佇列
2. M 從綁定的 P 的本地佇列取 G 執行
3. 本地佇列空了 → 從 Global Queue 偷、或從其他 P 偷 (Work Stealing)
4. G 遇到 I/O 阻塞 → M 與 P 解綁，P 找另一個 M 繼續跑其他 G

> **提示**：可用 `runtime.GOMAXPROCS(n)` 設定 P 的數量，但通常不需要調整。預設值（CPU 核心數）在大多數場景下已是最優。
{: .note }

---

## 二、Goroutine 基礎用法

### 啟動方式

```go
// 方式 1：匿名函式
go func() {
    fmt.Println("anonymous goroutine")
}()

// 方式 2：具名函式
go processTask(task)

// 方式 3：方法呼叫
go service.Handle(request)
```

### 等待 Goroutine 完成：sync.WaitGroup

```go
func main() {
    var wg sync.WaitGroup

    for i := 0; i < 5; i++ {
        wg.Add(1)
        go func(id int) {
            defer wg.Done()
            fmt.Printf("Worker %d 完成\n", id)
        }(i)
    }

    wg.Wait()  // 阻塞直到所有 Goroutine 完成
    fmt.Println("全部完成")
}
```

| 方法 | 說明 |
|:-----|:-----|
| `wg.Add(n)` | 計數器 +n，通常在啟動 Goroutine 前呼叫 |
| `wg.Done()` | 計數器 -1，通常用 `defer wg.Done()` |
| `wg.Wait()` | 阻塞直到計數器歸零 |

> **注意**：`wg.Add(1)` 必須在 `go func()` **之前**呼叫，不是在 Goroutine 內部。否則 `Wait()` 可能在 `Add()` 之前就返回了。
{: .warning }

```go
// 錯誤寫法
for i := 0; i < 5; i++ {
    go func(id int) {
        wg.Add(1)  // 太晚了！Wait() 可能已經返回
        defer wg.Done()
        doWork(id)
    }(i)
}
wg.Wait()

// 正確寫法
for i := 0; i < 5; i++ {
    wg.Add(1)  // 在 go 之前
    go func(id int) {
        defer wg.Done()
        doWork(id)
    }(i)
}
wg.Wait()
```

---

## 三、Channel 的本質

### 什麼是 Channel？

Channel 是 Goroutine 之間的通訊管道，用來安全地傳遞資料。

```go
// 建立 Channel
ch := make(chan int)       // 無緩衝 Channel
ch := make(chan int, 10)   // 有緩衝 Channel (容量 10)
```

### 無緩衝 vs 有緩衝

```
無緩衝 (Unbuffered)             有緩衝 (Buffered)
┌──────────┐                   ┌──────────────────┐
│ 發送者    │── 同步交接 ──│ 接收者    │   │ 發送者 ──→ [□ □ □] ──→ 接收者  │
│ (阻塞直到 │                │ (阻塞直到 │   │           緩衝區              │
│  有人收)  │                │  有人送)  │   │  (滿了才阻塞)  (空了才阻塞)  │
└──────────┘                   └──────────────────┘
```

| 特性 | 無緩衝 `make(chan T)` | 有緩衝 `make(chan T, n)` |
|:-----|:-----|:-----|
| 發送阻塞 | 直到有人接收 | 直到緩衝區滿 |
| 接收阻塞 | 直到有人發送 | 直到緩衝區空 |
| 同步性 | 強同步 (握手) | 非同步 (解耦) |
| 用途 | 信號傳遞、同步協作 | 生產者-消費者、限速 |

```go
// 無緩衝：發送和接收必須同時就緒
ch := make(chan int)

go func() {
    ch <- 42  // 阻塞，直到 main goroutine 準備接收
}()

val := <-ch  // 阻塞，直到有值被發送
fmt.Println(val)  // 42

// 有緩衝：可以先塞再取
ch := make(chan int, 2)
ch <- 1  // 不阻塞 (緩衝區有空間)
ch <- 2  // 不阻塞
// ch <- 3  // 會阻塞！緩衝區滿了

fmt.Println(<-ch)  // 1
fmt.Println(<-ch)  // 2
```

### Channel 的方向 (Direction)

```go
// 雙向 Channel (預設)
ch := make(chan int)

// 只發送 (Send-only)
func producer(ch chan<- int) {
    ch <- 42
    // val := <-ch  // 編譯錯誤！
}

// 只接收 (Receive-only)
func consumer(ch <-chan int) {
    val := <-ch
    // ch <- 42  // 編譯錯誤！
}
```

> **提示**：在函式簽名中使用方向限制，是 Go 的最佳實踐。編譯器會幫你檢查，防止誤用。
{: .note }

### Channel 的零值

```go
var ch chan int  // nil channel

// nil channel 的行為
ch <- 1   // 永遠阻塞
<-ch      // 永遠阻塞
close(ch) // panic!
```

> **注意**：未初始化的 Channel 是 `nil`，對它發送或接收會永遠阻塞 (不是 panic)。只有 `close(nil channel)` 才會 panic。
{: .warning }

---

## 四、Channel 操作完全手冊

### 發送、接收、關閉

```go
ch := make(chan int, 3)

// 發送
ch <- 1
ch <- 2
ch <- 3

// 關閉
close(ch)

// 關閉後的行為
// ch <- 4       // panic: send on closed channel
val, ok := <-ch  // val=1, ok=true (還有資料)
val, ok = <-ch   // val=2, ok=true
val, ok = <-ch   // val=3, ok=true
val, ok = <-ch   // val=0, ok=false (已關閉且空)
```

**關閉規則總結**：

| 操作 | 開啟的 Channel | 已關閉的 Channel | nil Channel |
|:-----|:-----|:-----|:-----|
| `ch <- v` | 正常/阻塞 | **panic** | 永遠阻塞 |
| `<-ch` | 正常/阻塞 | 立即回傳零值 | 永遠阻塞 |
| `close(ch)` | 正常關閉 | **panic** | **panic** |
| `len(ch)` | 目前元素數 | 目前元素數 | 0 |
| `cap(ch)` | 緩衝容量 | 緩衝容量 | 0 |

> **嚴重**：只有發送者應該關閉 Channel，接收者不應該關閉。重複關閉 Channel 會 panic。
{: .important }

### 用 range 遍歷 Channel

```go
ch := make(chan int, 5)

go func() {
    for i := 0; i < 5; i++ {
        ch <- i
    }
    close(ch)  // 必須關閉，否則 range 會永遠阻塞
}()

for val := range ch {
    fmt.Println(val)  // 0, 1, 2, 3, 4
}
// range 會在 channel 關閉且讀完所有值後自動退出
```

### 用 comma-ok 判斷 Channel 是否關閉

```go
val, ok := <-ch
if !ok {
    fmt.Println("Channel 已關閉")
}
```

---

## 五、Select：多路複用

### 基本語法

```go
select {
case val := <-ch1:
    fmt.Println("從 ch1 收到:", val)
case ch2 <- data:
    fmt.Println("發送到 ch2 成功")
case <-time.After(3 * time.Second):
    fmt.Println("超時")
default:
    fmt.Println("沒有 channel 就緒 (non-blocking)")
}
```

### Select 的行為規則

| 情境 | 行為 |
|:-----|:-----|
| 一個 case 就緒 | 執行該 case |
| 多個 case 就緒 | **隨機**選擇一個 (公平) |
| 沒有 case 就緒且有 default | 執行 default (non-blocking) |
| 沒有 case 就緒且無 default | 阻塞直到某個 case 就緒 |
| 空 select `select{}` | 永遠阻塞 (可用來防止 main 退出) |

### 超時控制

```go
func fetchWithTimeout(url string, timeout time.Duration) (string, error) {
    ch := make(chan string, 1)

    go func() {
        ch <- httpGet(url)
    }()

    select {
    case result := <-ch:
        return result, nil
    case <-time.After(timeout):
        return "", fmt.Errorf("請求 %s 超時 (%v)", url, timeout)
    }
}
```

> **注意**：`time.After` 在 select 迴圈中使用會造成記憶體洩漏（每次迴圈都建立新 Timer）。長時間運行的 select 迴圈應使用 `time.NewTimer` 搭配 `Reset`。
{: .warning }

```go
// 錯誤寫法：time.After 在迴圈中洩漏
for {
    select {
    case msg := <-ch:
        handle(msg)
    case <-time.After(5 * time.Second):  // 每次迴圈都建立新 Timer！
        fmt.Println("idle")
    }
}

// 正確寫法：重用 Timer
timer := time.NewTimer(5 * time.Second)
defer timer.Stop()

for {
    select {
    case msg := <-ch:
        if !timer.Stop() {
            <-timer.C
        }
        timer.Reset(5 * time.Second)
        handle(msg)
    case <-timer.C:
        fmt.Println("idle")
        timer.Reset(5 * time.Second)
    }
}
```

### Non-blocking 操作

```go
// Non-blocking 發送
select {
case ch <- value:
    fmt.Println("發送成功")
default:
    fmt.Println("Channel 滿了，跳過")
}

// Non-blocking 接收
select {
case val := <-ch:
    fmt.Println("收到:", val)
default:
    fmt.Println("沒有資料")
}
```

---

## 六、經典並發模式

### 模式 1：Fan-Out / Fan-In

**Fan-Out**：一個輸入分發到多個 Goroutine 處理。
**Fan-In**：多個 Goroutine 的結果合併到一個 Channel。

```go
// Fan-Out: 分發任務
func fanOut(tasks <-chan int, workerCount int) []<-chan int {
    workers := make([]<-chan int, workerCount)
    for i := 0; i < workerCount; i++ {
        workers[i] = worker(tasks)
    }
    return workers
}

func worker(tasks <-chan int) <-chan int {
    out := make(chan int)
    go func() {
        defer close(out)
        for task := range tasks {
            out <- process(task)
        }
    }()
    return out
}

// Fan-In: 合併結果
func fanIn(channels ...<-chan int) <-chan int {
    merged := make(chan int)
    var wg sync.WaitGroup

    for _, ch := range channels {
        wg.Add(1)
        go func(c <-chan int) {
            defer wg.Done()
            for val := range c {
                merged <- val
            }
        }(ch)
    }

    go func() {
        wg.Wait()
        close(merged)
    }()

    return merged
}

// 使用
func main() {
    tasks := make(chan int, 100)
    go func() {
        for i := 0; i < 100; i++ {
            tasks <- i
        }
        close(tasks)
    }()

    workers := fanOut(tasks, 5)       // 5 個 worker
    results := fanIn(workers...)       // 合併結果

    for result := range results {
        fmt.Println(result)
    }
}
```

### 模式 2：Pipeline

```go
// Stage 1: 產生數字
func generate(nums ...int) <-chan int {
    out := make(chan int)
    go func() {
        defer close(out)
        for _, n := range nums {
            out <- n
        }
    }()
    return out
}

// Stage 2: 平方
func square(in <-chan int) <-chan int {
    out := make(chan int)
    go func() {
        defer close(out)
        for n := range in {
            out <- n * n
        }
    }()
    return out
}

// Stage 3: 過濾偶數
func filterEven(in <-chan int) <-chan int {
    out := make(chan int)
    go func() {
        defer close(out)
        for n := range in {
            if n%2 == 0 {
                out <- n
            }
        }
    }()
    return out
}

// 組裝 Pipeline
func main() {
    ch := generate(1, 2, 3, 4, 5)
    ch = square(ch)
    ch = filterEven(ch)

    for val := range ch {
        fmt.Println(val)  // 4, 16
    }
}
```

### 模式 3：Worker Pool

```go
func workerPool(jobs <-chan Job, results chan<- Result, workerCount int) {
    var wg sync.WaitGroup

    for i := 0; i < workerCount; i++ {
        wg.Add(1)
        go func(id int) {
            defer wg.Done()
            for job := range jobs {
                result := processJob(id, job)
                results <- result
            }
        }(i)
    }

    // 等所有 worker 結束後關閉 results
    go func() {
        wg.Wait()
        close(results)
    }()
}

// 使用
func main() {
    jobs := make(chan Job, 100)
    results := make(chan Result, 100)

    // 啟動 Worker Pool
    workerPool(jobs, results, 10)

    // 發送任務
    go func() {
        for i := 0; i < 50; i++ {
            jobs <- Job{ID: i}
        }
        close(jobs)
    }()

    // 收集結果
    for result := range results {
        fmt.Printf("Job %d 結果: %v\n", result.JobID, result.Data)
    }
}
```

### 模式 4：Semaphore (信號量限速)

```go
// 用有緩衝 Channel 實作信號量
func processAll(urls []string, maxConcurrent int) {
    sem := make(chan struct{}, maxConcurrent)
    var wg sync.WaitGroup

    for _, url := range urls {
        wg.Add(1)
        go func(u string) {
            defer wg.Done()

            sem <- struct{}{}        // 取得令牌 (滿了就阻塞)
            defer func() { <-sem }() // 歸還令牌

            fetch(u)
        }(url)
    }

    wg.Wait()
}

// 實務上更推薦用 semaphore package
import "golang.org/x/sync/semaphore"

func processAll(ctx context.Context, urls []string, maxConcurrent int64) error {
    sem := semaphore.NewWeighted(maxConcurrent)
    g, ctx := errgroup.WithContext(ctx)

    for _, url := range urls {
        if err := sem.Acquire(ctx, 1); err != nil {
            return err
        }
        g.Go(func() error {
            defer sem.Release(1)
            return fetch(ctx, url)
        })
    }
    return g.Wait()
}
```

### 模式 5：Done Channel (退出信號)

```go
func worker(done <-chan struct{}) {
    for {
        select {
        case <-done:
            fmt.Println("收到退出信號")
            return
        default:
            doWork()
        }
    }
}

func main() {
    done := make(chan struct{})

    go worker(done)
    go worker(done)
    go worker(done)

    time.Sleep(5 * time.Second)
    close(done)  // 關閉 channel 會通知所有監聽者 (broadcast)
}
```

> **提示**：`close(done)` 是一種廣播機制 — 所有在 `<-done` 上等待的 Goroutine 都會同時收到信號。這比逐個發送更優雅。
{: .note }

### 模式 6：Or-Done Channel

```go
// 任一完成就回傳 (First Response Wins)
func fetchFastest(ctx context.Context, urls []string) (string, error) {
    ctx, cancel := context.WithCancel(ctx)
    defer cancel()

    type result struct {
        body string
        err  error
    }

    ch := make(chan result, len(urls))

    for _, url := range urls {
        go func(u string) {
            body, err := fetchURL(ctx, u)
            ch <- result{body, err}
        }(url)
    }

    // 取第一個成功的結果
    for range urls {
        r := <-ch
        if r.err == nil {
            cancel()  // 取消其他 Goroutine
            return r.body, nil
        }
    }
    return "", fmt.Errorf("all requests failed")
}
```

### 模式 7：Ticker (定期執行)

```go
func periodicTask(ctx context.Context, interval time.Duration) {
    ticker := time.NewTicker(interval)
    defer ticker.Stop()

    for {
        select {
        case <-ticker.C:
            doPeriodicWork()
        case <-ctx.Done():
            log.Println("定期任務已停止")
            return
        }
    }
}
```

---

## 七、sync 套件：共享記憶體工具箱

### sync.Mutex (互斥鎖)

```go
type SafeCounter struct {
    mu sync.Mutex
    v  map[string]int
}

func (c *SafeCounter) Inc(key string) {
    c.mu.Lock()
    defer c.mu.Unlock()
    c.v[key]++
}

func (c *SafeCounter) Value(key string) int {
    c.mu.Lock()
    defer c.mu.Unlock()
    return c.v[key]
}
```

### sync.RWMutex (讀寫鎖)

```go
type Cache struct {
    mu   sync.RWMutex
    data map[string]string
}

// 讀操作：允許多個 Goroutine 同時讀
func (c *Cache) Get(key string) (string, bool) {
    c.mu.RLock()
    defer c.mu.RUnlock()
    val, ok := c.data[key]
    return val, ok
}

// 寫操作：獨佔
func (c *Cache) Set(key, value string) {
    c.mu.Lock()
    defer c.mu.Unlock()
    c.data[key] = value
}
```

| 鎖類型 | 讀-讀 | 讀-寫 | 寫-寫 | 適用場景 |
|:-----|:-----|:-----|:-----|:-----|
| `Mutex` | 互斥 | 互斥 | 互斥 | 讀寫頻率相近 |
| `RWMutex` | **並行** | 互斥 | 互斥 | 讀多寫少 |

### sync.Once (只執行一次)

```go
var (
    instance *Database
    once     sync.Once
)

func GetDB() *Database {
    once.Do(func() {
        instance = connectDB()  // 只會執行一次，即使多個 Goroutine 同時呼叫
    })
    return instance
}
```

### sync.Map (並發安全 Map)

```go
var m sync.Map

// 寫入
m.Store("key", "value")

// 讀取
val, ok := m.Load("key")

// 不存在才寫入
actual, loaded := m.LoadOrStore("key", "default")

// 刪除
m.Delete("key")

// 遍歷
m.Range(func(key, value any) bool {
    fmt.Println(key, value)
    return true  // 回傳 false 可提早停止
})
```

| 方案 | 適用場景 |
|:-----|:-----|
| `map` + `Mutex` | 一般情況 (效能更好、型別安全) |
| `map` + `RWMutex` | 讀多寫少 |
| `sync.Map` | key 穩定的場景 (寫一次讀多次)、不同 Goroutine 操作不重疊的 key |

> **提示**：大多數場景下 `map` + `RWMutex` 比 `sync.Map` 效能更好且有型別安全。`sync.Map` 的優勢在特定場景 (key 集合穩定、各 Goroutine 操作的 key 不重疊)。
{: .note }

### sync.Cond (條件變數)

```go
type Queue struct {
    mu    sync.Mutex
    cond  *sync.Cond
    items []int
}

func NewQueue() *Queue {
    q := &Queue{}
    q.cond = sync.NewCond(&q.mu)
    return q
}

func (q *Queue) Enqueue(item int) {
    q.mu.Lock()
    defer q.mu.Unlock()
    q.items = append(q.items, item)
    q.cond.Signal()  // 通知一個等待者
}

func (q *Queue) Dequeue() int {
    q.mu.Lock()
    defer q.mu.Unlock()
    for len(q.items) == 0 {
        q.cond.Wait()  // 釋放鎖並等待通知
    }
    item := q.items[0]
    q.items = q.items[1:]
    return item
}
```

| 方法 | 說明 |
|:-----|:-----|
| `cond.Wait()` | 釋放鎖 + 等待通知 + 重新取鎖 |
| `cond.Signal()` | 通知一個等待中的 Goroutine |
| `cond.Broadcast()` | 通知所有等待中的 Goroutine |

---

## 八、避坑指南 (必讀)

### 1. Goroutine 洩漏 (最常見！)

> **嚴重**：洩漏的 Goroutine 永遠不會被 GC 回收，長時間運行會吃掉所有記憶體！
{: .important }

```go
// 洩漏 1：沒人接收
func leak1() {
    ch := make(chan int)
    go func() {
        ch <- expensiveWork()  // 永遠阻塞，因為沒人接收
    }()
    // 函式返回了，Goroutine 永遠卡住
}

// 洩漏 2：沒人發送
func leak2() {
    ch := make(chan int)
    go func() {
        val := <-ch  // 永遠阻塞，因為沒人發送
        process(val)
    }()
}

// 洩漏 3：忘記關閉 Channel
func leak3() {
    ch := make(chan int)
    go func() {
        for val := range ch {  // 永遠等待，因為 ch 沒被關閉
            process(val)
        }
    }()
}
```

**檢測方式**：

```go
import "runtime"

// 在測試中檢查 Goroutine 數量
func TestNoLeak(t *testing.T) {
    before := runtime.NumGoroutine()
    doSomething()
    time.Sleep(100 * time.Millisecond)
    after := runtime.NumGoroutine()
    if after > before {
        t.Errorf("Goroutine 洩漏: before=%d, after=%d", before, after)
    }
}

// 或使用 goleak (uber 出品)
import "go.uber.org/goleak"

func TestMain(m *testing.M) {
    goleak.VerifyTestMain(m)
}
```

### 2. 對已關閉的 Channel 發送

```go
ch := make(chan int)
close(ch)
ch <- 1  // panic: send on closed channel
```

**解法**：只由發送者關閉 Channel，接收者永遠不關閉。

```go
// 安全模式：發送者負責關閉
func producer(ch chan<- int) {
    defer close(ch)  // 發送者關閉
    for i := 0; i < 10; i++ {
        ch <- i
    }
}

func consumer(ch <-chan int) {
    for val := range ch {  // 接收者只負責讀
        process(val)
    }
}
```

### 3. 迴圈變數捕獲 (Go < 1.22)

```go
// 錯誤寫法 (Go < 1.22)
for i := 0; i < 5; i++ {
    go func() {
        fmt.Println(i)  // 可能全部印 5
    }()
}

// 正確寫法
for i := 0; i < 5; i++ {
    go func(n int) {
        fmt.Println(n)
    }(i)
}
```

> **好消息**：Go 1.22+ 已修復迴圈變數捕獲問題，但維護舊程式碼時仍需注意。
{: .note }

### 4. Data Race (資料競爭)

```go
// 錯誤寫法：多個 Goroutine 同時讀寫
counter := 0
for i := 0; i < 1000; i++ {
    go func() {
        counter++  // Data Race! 結果不可預測
    }()
}

// 正確寫法 1：Mutex
var mu sync.Mutex
counter := 0
for i := 0; i < 1000; i++ {
    go func() {
        mu.Lock()
        counter++
        mu.Unlock()
    }()
}

// 正確寫法 2：atomic (更快)
var counter int64
for i := 0; i < 1000; i++ {
    go func() {
        atomic.AddInt64(&counter, 1)
    }()
}

// 正確寫法 3：Channel
counter := 0
ch := make(chan int, 1000)
for i := 0; i < 1000; i++ {
    go func() {
        ch <- 1
    }()
}
for i := 0; i < 1000; i++ {
    counter += <-ch
}
```

**檢測方式**：

```bash
# Go 內建的 Race Detector
go run -race main.go
go test -race ./...
```

> **注意**：Data Race 是未定義行為 (Undefined Behavior)，不只是結果不正確，可能導致程式崩潰或記憶體損壞。永遠在 CI 中開啟 `-race` 檢測。
{: .warning }

### 5. Deadlock (死鎖)

```go
// 死鎖 1：無緩衝 Channel 在同一個 Goroutine 發送和接收
func deadlock1() {
    ch := make(chan int)
    ch <- 1  // 永遠阻塞，因為沒有其他 Goroutine 來接收
    fmt.Println(<-ch)
}

// 死鎖 2：兩個 Goroutine 互相等待
func deadlock2() {
    ch1 := make(chan int)
    ch2 := make(chan int)

    go func() {
        val := <-ch1  // 等 ch1
        ch2 <- val    // 再送 ch2
    }()

    go func() {
        val := <-ch2  // 等 ch2
        ch1 <- val    // 再送 ch1
    }()
    // 兩個 Goroutine 互相等待，死鎖！
}

// 死鎖 3：Mutex 重複加鎖
func deadlock3() {
    var mu sync.Mutex
    mu.Lock()
    mu.Lock()  // 同一個 Goroutine 再次加鎖，死鎖！
}
```

### 6. 在 select 中 break 只跳出 select

```go
// 常見錯誤：以為 break 會跳出 for 迴圈
for {
    select {
    case <-ch:
        break  // 只跳出 select，不跳出 for！
    }
}

// 正確寫法 1：使用 label
Loop:
    for {
        select {
        case <-ch:
            break Loop  // 跳出 for 迴圈
        }
    }

// 正確寫法 2：return
for {
    select {
    case <-ch:
        return
    }
}
```

---

## 九、Channel vs Mutex 選擇指南

| 場景 | 建議 | 原因 |
|:-----|:-----|:-----|
| 傳遞資料所有權 | Channel | 資料隨 Channel 流動，天然無競爭 |
| 通知/信號 | Channel | `close(ch)` 是完美的廣播機制 |
| 簡單計數器 | `atomic` | 最快，零開銷 |
| 保護共享資料結構 | `Mutex` | 比 Channel 更直觀、效能更好 |
| 讀多寫少的快取 | `RWMutex` | 允許多讀並行 |
| Worker Pool | Channel | 天然的任務佇列 |
| 限制並發數 | Buffered Channel / Semaphore | 容量 = 並發上限 |

> **經驗法則**：如果你在用 Channel 模擬鎖，用 Mutex。如果你在用 Mutex 模擬佇列，用 Channel。選擇讓程式碼最容易理解的方案。
{: .note }

---

## 十、atomic 套件：無鎖操作

```go
import "sync/atomic"

// 基本操作
var counter int64

atomic.AddInt64(&counter, 1)                      // 原子加
atomic.AddInt64(&counter, -1)                     // 原子減
val := atomic.LoadInt64(&counter)                 // 原子讀
atomic.StoreInt64(&counter, 100)                  // 原子寫
swapped := atomic.CompareAndSwapInt64(&counter, 100, 200) // CAS

// Go 1.19+: 泛型 atomic 類型
var counter atomic.Int64
counter.Add(1)
counter.Store(100)
val := counter.Load()

var flag atomic.Bool
flag.Store(true)
if flag.Load() {
    // ...
}

// 用 atomic.Value 存任意類型 (常用於 config hot reload)
var config atomic.Value

// 寫入 (通常在初始化或背景更新)
config.Store(&Config{Debug: true, Port: 8080})

// 讀取 (高頻、無鎖)
cfg := config.Load().(*Config)
```

| 方案 | 適用場景 | 效能 |
|:-----|:-----|:-----|
| `atomic` | 簡單數值操作 (計數器、旗標) | 最快 |
| `Mutex` | 複雜的臨界區操作 | 中等 |
| `Channel` | Goroutine 間通訊、所有權轉移 | 較慢 |

---

## 十一、errgroup：生產級並發控制

```go
import "golang.org/x/sync/errgroup"

func fetchAllUsers(ctx context.Context, ids []int) ([]*User, error) {
    g, ctx := errgroup.WithContext(ctx)
    users := make([]*User, len(ids))

    for i, id := range ids {
        g.Go(func() error {
            user, err := fetchUser(ctx, id)
            if err != nil {
                return fmt.Errorf("fetch user %d: %w", id, err)
            }
            users[i] = user
            return nil
        })
    }

    if err := g.Wait(); err != nil {
        return nil, err  // 回傳第一個錯誤
    }
    return users, nil
}
```

### 限制並發數

```go
g, ctx := errgroup.WithContext(ctx)
g.SetLimit(10)  // 最多 10 個 Goroutine 同時執行

for _, url := range urls {
    g.Go(func() error {
        return fetch(ctx, url)
    })
}

if err := g.Wait(); err != nil {
    log.Fatal(err)
}
```

> **提示**：`errgroup` 是生產環境中最常用的並發工具，幾乎所有需要「啟動多個 Goroutine → 等待全部完成 → 收集錯誤」的場景都該用它。
{: .note }

---

## 十二、完整實戰範例

### 生產等級的並發爬蟲

```go
package main

import (
    "context"
    "fmt"
    "io"
    "log"
    "net/http"
    "sync"
    "time"

    "golang.org/x/sync/errgroup"
)

type FetchResult struct {
    URL        string
    Body       string
    StatusCode int
    Duration   time.Duration
    Err        error
}

// 並發爬蟲 (限制同時請求數)
func ConcurrentFetch(ctx context.Context, urls []string, maxConcurrent int) []FetchResult {
    results := make([]FetchResult, len(urls))
    g, ctx := errgroup.WithContext(ctx)
    g.SetLimit(maxConcurrent)

    client := &http.Client{Timeout: 10 * time.Second}

    for i, url := range urls {
        g.Go(func() error {
            start := time.Now()

            req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
            if err != nil {
                results[i] = FetchResult{URL: url, Err: err}
                return nil  // 不中斷其他請求
            }

            resp, err := client.Do(req)
            if err != nil {
                results[i] = FetchResult{URL: url, Err: err, Duration: time.Since(start)}
                return nil
            }
            defer resp.Body.Close()

            body, err := io.ReadAll(resp.Body)
            results[i] = FetchResult{
                URL:        url,
                Body:       string(body),
                StatusCode: resp.StatusCode,
                Duration:   time.Since(start),
                Err:        err,
            }
            return nil
        })
    }

    g.Wait()
    return results
}

// Worker Pool + Pipeline 模式
func ProcessPipeline(ctx context.Context) {
    // Stage 1: 產生任務
    tasks := generateTasks(ctx)

    // Stage 2: 並發處理 (3 個 worker)
    processed := fanOutProcess(ctx, tasks, 3)

    // Stage 3: 收集結果
    for result := range processed {
        log.Printf("完成: %v", result)
    }
}

func generateTasks(ctx context.Context) <-chan int {
    out := make(chan int)
    go func() {
        defer close(out)
        for i := 0; i < 100; i++ {
            select {
            case out <- i:
            case <-ctx.Done():
                return
            }
        }
    }()
    return out
}

func fanOutProcess(ctx context.Context, in <-chan int, workers int) <-chan string {
    out := make(chan string)
    var wg sync.WaitGroup

    for i := 0; i < workers; i++ {
        wg.Add(1)
        go func(id int) {
            defer wg.Done()
            for task := range in {
                select {
                case out <- fmt.Sprintf("worker-%d processed task-%d", id, task):
                case <-ctx.Done():
                    return
                }
            }
        }(i)
    }

    go func() {
        wg.Wait()
        close(out)
    }()
    return out
}

func main() {
    ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
    defer cancel()

    // 範例 1: 並發爬蟲
    urls := []string{
        "https://httpbin.org/get",
        "https://httpbin.org/delay/1",
        "https://httpbin.org/status/404",
    }

    results := ConcurrentFetch(ctx, urls, 5)
    for _, r := range results {
        if r.Err != nil {
            log.Printf("[FAIL] %s: %v", r.URL, r.Err)
        } else {
            log.Printf("[OK] %s: %d (%v)", r.URL, r.StatusCode, r.Duration)
        }
    }

    // 範例 2: Pipeline
    ProcessPipeline(ctx)
}
```

---

## 十三、常見面試題

### Q1：Goroutine 和 Thread 的差別？
- **Goroutine** 由 Go runtime 排程 (User Space)，Stack 從 2KB 動態成長，建立成本極低
- **Thread** 由 OS 排程 (Kernel Space)，Stack 固定 1MB，建立成本高
- 百萬個 Goroutine 沒問題，百萬個 Thread 會直接 OOM

### Q2：無緩衝 Channel 和有緩衝 Channel 的差別？
- **無緩衝**：發送和接收必須同時就緒 (同步握手)，適合信號傳遞
- **有緩衝**：發送不阻塞直到滿、接收不阻塞直到空 (非同步)，適合生產者-消費者

### Q3：如何優雅地停止 Goroutine？
1. 使用 `context.WithCancel`，在 Goroutine 中監聽 `ctx.Done()`
2. 使用 done channel，通過 `close(done)` 廣播
3. 使用 `sync.WaitGroup` 等待所有 Goroutine 結束
4. **不能**強制殺死 Goroutine，只能「請求」它退出 (協作式)

### Q4：以下程式碼會輸出什麼？

```go
func main() {
    ch := make(chan int, 1)
    ch <- 1
    go func() {
        ch <- 2
    }()
    fmt.Println(<-ch)
}
```

**答案**：`1`。有緩衝 Channel 已有值 1，main Goroutine 直接讀到 1。Goroutine 可能來不及執行程式就結束了。

### Q5：如何檢測 Goroutine 洩漏？
- `runtime.NumGoroutine()` 監控數量
- `go test -race` 檢測 data race
- `go.uber.org/goleak` 在測試中自動檢測
- pprof endpoint: `/debug/pprof/goroutine`

### Q6：select 中所有 case 都沒準備好且沒有 default 會怎樣？
- 會**阻塞**直到某個 case 就緒
- 如果有 default，則立即執行 default (non-blocking)
- 空的 `select{}` 會永遠阻塞

### Q7：Channel 和 Mutex 各自適合什麼場景？
- **Channel**：Goroutine 間傳遞資料的所有權、通知/信號、Pipeline、Worker Pool
- **Mutex**：保護共享資料結構 (如 map、slice)、臨界區操作
- **atomic**：簡單數值操作 (計數器、旗標)

---

## 十四、最佳實踐總結

### Do's (建議做法)

| 實踐 | 說明 |
|:-----|:-----|
| 用 Channel 傳遞所有權 | 資料隨 Channel 流動，避免共享 |
| 永遠處理 Goroutine 的退出 | 用 context 或 done channel 通知退出 |
| 發送者關閉 Channel | 接收者不應該關閉 |
| 使用 `-race` 檢測 | CI 中必開 `go test -race` |
| 使用 errgroup | 取代手動 WaitGroup + error 收集 |
| Channel 方向限制 | 函式簽名中用 `chan<-` / `<-chan` |
| 預設用 Mutex 保護共享資料 | 比 Channel 更直觀、效能更好 |

### Don'ts (避免做法)

| 避免 | 原因 |
|:-----|:-----|
| fire-and-forget Goroutine | 無法得知是否完成或出錯，可能洩漏 |
| 不關閉 range 的 Channel | 導致接收方永遠阻塞 |
| 接收者關閉 Channel | 發送者可能 panic |
| 用 `time.After` 在迴圈中 | 每次迭代都建立新 Timer，記憶體洩漏 |
| 在沒有同步的情況下讀寫共享變數 | Data Race，未定義行為 |
| 用 `select{}` 當作等待機制 | 應該用 WaitGroup 或 Channel 明確等待 |
| 忽略 `-race` 的警告 | Data Race 是嚴重 bug，不是 warning |

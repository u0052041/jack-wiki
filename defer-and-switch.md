---
layout: default
title: Defer & Switch 語法範例全集
nav_order: 7
---

# Go 進階筆記：Defer & Switch 語法範例全集
{: .no_toc }

核心機制、常見陷阱與實戰技巧
{: .fs-6 .fw-300 }

## 目錄
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## 一、Switch 的各種變體

### 1. 標準值比對 (Value Switch)
```go
switch os := runtime.GOOS; os {
case "darwin":
    fmt.Println("macOS")
case "linux", "freebsd":  // 多值比對
    fmt.Println("Unix-like")
default:
    fmt.Println("其他系統")
}
```

### 2. 無條件模式 (Expressionless - 替代 if-else)
```go
score := 85
switch {
case score >= 90:
    fmt.Println("A")
case score >= 80:
    fmt.Println("B")
default:
    fmt.Println("C")
}
```

### 3. 型別開關 (Type Switch)
```go
func check(i any) {
    switch v := i.(type) {
    case int:
        fmt.Println("這是整數:", v+1)
    case string:
        fmt.Println("這是字串:", v+"!")
    case *Order:  // 指標型別判斷
        fmt.Println("訂單 ID:", v.ID)
    }
}
```

---

## 二、Defer 的核心範例

### 1. 資源清理 (最常見用法)
```go
f, _ := os.Open("test.txt")
defer f.Close()  // 確保函式結束前一定會關閉檔案
```

### 2. LIFO (後進先出)
```go
defer fmt.Println("1")
defer fmt.Println("2")
defer fmt.Println("3")
// 輸出順序: 3 -> 2 -> 1
```

### 3. 立即求值陷阱
```go
x := 10
defer fmt.Println("defer 取到的 x:", x)  // 這裡會立刻捕捉 x=10
x = 20
fmt.Println("目前的 x:", x)

// 執行結果:
// 目前的 x: 20
// defer 取到的 x: 10
```

> **重點**：defer 的參數在「註冊時」就求值，不是「執行時」。
{: .note }

### 4. Defer 修改返回值 (具名返回值)

```go
func example() (result int) {
    defer func() {
        result++  // 可以修改具名返回值
    }()
    return 0  // 實際返回 1
}

fmt.Println(example())  // 1
```

**執行順序**：
1. `result = 0` (return 賦值)
2. defer 執行 `result++`
3. 函式真正返回 `result` (此時是 1)

### 5. Defer 與 Panic/Recover

```go
func safeCall() {
    defer func() {
        if r := recover(); r != nil {
            fmt.Println("捕獲 panic:", r)
        }
    }()

    panic("出事了！")
    fmt.Println("這行不會執行")
}

safeCall()
fmt.Println("程式繼續執行")
// 輸出:
// 捕獲 panic: 出事了！
// 程式繼續執行
```

> **注意**：`recover()` 只能在 defer 函式中呼叫才有效。
{: .warning }

---

## 三、Defer 常見陷阱

### 陷阱 1：迴圈中的 Defer (資源洩漏)

```go
// 錯誤：所有檔案都在函式結束才關閉
func processFiles(paths []string) error {
    for _, path := range paths {
        f, err := os.Open(path)
        if err != nil {
            return err
        }
        defer f.Close()  // 危險！可能耗盡 file descriptors
        // 處理檔案...
    }
    return nil
}

// 正確：用匿名函式限制 defer 作用域
func processFiles(paths []string) error {
    for _, path := range paths {
        if err := func() error {
            f, err := os.Open(path)
            if err != nil {
                return err
            }
            defer f.Close()  // 每次迭代結束就關閉
            // 處理檔案...
            return nil
        }(); err != nil {
            return err
        }
    }
    return nil
}
```

### 陷阱 2：Defer nil 函式

```go
var cleanup func()  // nil

defer cleanup()  // panic: runtime error: invalid memory address

// 安全寫法
if cleanup != nil {
    defer cleanup()
}
```

### 陷阱 3：Defer 在錯誤檢查之前

```go
// 錯誤：f 可能是 nil
f, err := os.Open("file.txt")
defer f.Close()  // 危險！如果 err != nil，f 是 nil
if err != nil {
    return err
}

// 正確：先檢查錯誤
f, err := os.Open("file.txt")
if err != nil {
    return err
}
defer f.Close()  // 安全
```

---

## 四、Switch 進階技巧

### 1. Fallthrough (穿透)

```go
switch n := 2; n {
case 1:
    fmt.Println("one")
case 2:
    fmt.Println("two")
    fallthrough  // 繼續執行下一個 case
case 3:
    fmt.Println("three")
}
// 輸出:
// two
// three
```

> **注意**：Go 的 switch 預設不穿透 (不像 C/Java)，需要明確使用 `fallthrough`。
{: .note }

### 2. 初始化語句

```go
switch os := runtime.GOOS; os {
case "darwin":
    fmt.Println("Mac")
case "linux":
    fmt.Println("Linux")
}
// os 只在 switch 區塊內有效
```

### 3. 多值匹配

```go
switch day {
case "Saturday", "Sunday":
    fmt.Println("週末")
case "Monday", "Tuesday", "Wednesday", "Thursday", "Friday":
    fmt.Println("工作日")
}
```

### 4. 介面型別判斷的完整模式

```go
func describe(i interface{}) string {
    switch v := i.(type) {
    case nil:
        return "nil"
    case int, int64:
        return fmt.Sprintf("整數: %v", v)
    case string:
        return fmt.Sprintf("字串長度: %d", len(v))
    case bool:
        if v {
            return "真"
        }
        return "假"
    case fmt.Stringer:  // 介面型別
        return v.String()
    default:
        return fmt.Sprintf("未知型別: %T", v)
    }
}
```

---

## 五、實戰範例

### Defer 實現計時器

```go
func timer(name string) func() {
    start := time.Now()
    return func() {
        fmt.Printf("%s 耗時: %v\n", name, time.Since(start))
    }
}

func slowOperation() {
    defer timer("slowOperation")()  // 注意：要呼叫兩次
    time.Sleep(100 * time.Millisecond)
}
// 輸出: slowOperation 耗時: 100.123ms
```

### Defer 實現互斥鎖

```go
var mu sync.Mutex

func criticalSection() {
    mu.Lock()
    defer mu.Unlock()  // 確保一定會解鎖

    // 關鍵區域...
    if someCondition {
        return  // 即使提前返回也會解鎖
    }
    // 更多操作...
}
```

### Switch 實現狀態機

```go
type State int

const (
    StateInit State = iota
    StateRunning
    StatePaused
    StateStopped
)

func (s State) Next(event string) State {
    switch s {
    case StateInit:
        if event == "start" {
            return StateRunning
        }
    case StateRunning:
        switch event {
        case "pause":
            return StatePaused
        case "stop":
            return StateStopped
        }
    case StatePaused:
        if event == "resume" {
            return StateRunning
        }
    }
    return s  // 保持原狀態
}
```

---

## 六、常見面試題

### Q1：Defer 的執行順序？
LIFO (後進先出)，像堆疊一樣。

### Q2：以下程式碼輸出什麼？

```go
func f() (r int) {
    defer func() { r++ }()
    return 0
}
```
**答案**：`1` — defer 可以修改具名返回值。

### Q3：以下程式碼輸出什麼？

```go
func f() int {
    r := 0
    defer func() { r++ }()
    return r
}
```
**答案**：`0` — 非具名返回值，defer 修改的是區域變數，不影響返回值。

### Q4：Switch 和 if-else 的選擇？

| 情境 | 建議 |
|:-----|:-----|
| 單一變數多值比對 | `switch` |
| 複雜條件判斷 | `if-else` |
| 型別判斷 | `switch v := i.(type)` |
| 範圍判斷 | `switch` (無條件模式)

---
layout: default
title: Error 錯誤處理完全指南
nav_order: 7
---

# Go 進階筆記：Error 錯誤處理完全指南
{: .no_toc }

從基礎到業界實戰
{: .fs-6 .fw-300 }

## 目錄
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## 一、Error 的本質

### error 是 Interface

```go
// Go 內建的 error 定義
type error interface {
    Error() string
}
```

**核心觀念**：只要實作 `Error() string` 方法，就是 error。

> **重點**：Go 的錯誤處理是透過「回傳值」而非「例外機制」(Exception)。這是 Go 的設計哲學 — 錯誤是值 (Errors are values)，應該被明確處理。
{: .note }

### 建立 error 的三種方式

```go
// 方式 1：errors.New (最簡單)
err := errors.New("發生錯誤")

// 方式 2：fmt.Errorf (可格式化)
err := fmt.Errorf("使用者 %s 不存在", username)

// 方式 3：自定義 struct (攜帶更多資訊)
type MyError struct {
    Code    int
    Message string
}

func (e *MyError) Error() string {
    return fmt.Sprintf("錯誤碼 %d: %s", e.Code, e.Message)
}
```

---

## 二、處理錯誤的黃金律

### 基本模式

```go
func DoSomething() (Result, error) {
    result, err := someOperation()
    if err != nil {
        return Result{}, err  // 檢查並傳遞
    }
    return result, nil  // 成功回傳 nil
}
```

| 規則 | 說明 |
|:-----|:-----|
| 檢查 | 永遠使用 `if err != nil` |
| 傳遞 | 回傳值最後一個位置永遠留給 error |
| 回傳 | 成功回傳 `nil`，失敗回傳 error 物件 |

> **注意**：不要忽略 error！使用 `_` 忽略錯誤是 Go 程式碼中最常見的 bug 來源之一。
{: .warning }

```go
// 錯誤寫法：忽略錯誤
data, _ := ioutil.ReadFile("config.json")  // 危險！

// 正確寫法：明確處理
data, err := ioutil.ReadFile("config.json")
if err != nil {
    log.Fatal("無法讀取設定檔:", err)
}
```

### Receiver 選擇邏輯

| 類型 | 建議 Receiver | 範例 |
|:-----|:-----|:-----|
| 簡單類型 (int, float64, string) | Value Receiver | `func (e MyFloat) Error() string` |
| 複雜類型 (Struct) | Pointer Receiver | `func (e *MyError) Error() string` |

---

## 三、避坑指南 (必讀)

### 1. 無窮迴圈陷阱 (Recursion Death)

> **嚴重**：這是 Go 新手最容易踩到的坑，會導致程式無限遞迴直到 stack overflow！
{: .important }

```go
type ErrNegativeSqrt float64

// 錯誤寫法：無窮迴圈
func (e ErrNegativeSqrt) Error() string {
    return fmt.Sprintf("無法計算負數的平方根: %v", e)
    // %v 會再次呼叫 Error()，造成無窮遞迴
}

// 正確寫法：轉回原始類型
func (e ErrNegativeSqrt) Error() string {
    return fmt.Sprintf("無法計算負數的平方根: %v", float64(e))
    // 轉成 float64 脫掉介面外殼
}
```

**原理解析**：
1. `fmt.Sprintf` 遇到 `%v` 時，會檢查該值是否實作 `error` 介面
2. 如果有，就呼叫 `Error()` 取得字串
3. 而 `Error()` 內部又用 `%v` 印自己，於是再次呼叫 `Error()`...
4. 無限循環直到 stack overflow

### 2. Log 重複列印

```go
// 錯誤寫法：每層都 log
func innerFunc() error {
    err := doSomething()
    if err != nil {
        log.Println(err)  // 底層 log
        return err
    }
    return nil
}

func outerFunc() error {
    err := innerFunc()
    if err != nil {
        log.Println(err)  // 又 log 一次，重複了！
        return err
    }
    return nil
}

// 正確寫法：只在最頂層 log
func main() {
    if err := outerFunc(); err != nil {
        log.Println(err)  // 統一在入口處理
    }
}
```

### 3. 指標接收者陷阱

```go
type MyError struct {
    Message string
}

// Method 定義在指標上
func (e *MyError) Error() string {
    return e.Message
}

// 錯誤寫法
func bad() error {
    return MyError{Message: "失敗"}  // 編譯錯誤！
}

// 正確寫法
func good() error {
    return &MyError{Message: "失敗"}  // 加上 &
}
```

### 4. 變數命名衝突

```go
// 錯誤寫法
error := doSomething()  // error 是內建類型！

// 正確寫法
err := doSomething()  // 用 err 當變數名
```

---

## 四、Sprintf vs Printf

| 函式 | 用途 | 範例 |
|:-----|:-----|:-----|
| `fmt.Printf` | 直接印到螢幕 (給人看) | `fmt.Printf("錯誤: %v", err)` |
| `fmt.Sprintf` | 組成字串回傳 (給程式用) | `return fmt.Sprintf("錯誤: %v", err)` |

```go
func (e *MyError) Error() string {
    // 用 Sprintf 組成字串回傳
    return fmt.Sprintf("[%d] %s", e.Code, e.Message)
}
```

---

## 五、業界實戰組合技

### 1. 定義：使用 Struct 攜帶資訊

```go
type APIError struct {
    Code    int    `json:"code"`
    Message string `json:"message"`
    Err     error  `json:"-"`  // 原始錯誤
}

func (e *APIError) Error() string {
    if e.Err != nil {
        return fmt.Sprintf("[%d] %s: %v", e.Code, e.Message, e.Err)
    }
    return fmt.Sprintf("[%d] %s", e.Code, e.Message)
}
```

### 2. 包裝：使用 %w 保留原始錯誤

```go
func readConfig(path string) error {
    data, err := os.ReadFile(path)
    if err != nil {
        // 用 %w 包裝，保留原始錯誤鏈
        return fmt.Errorf("讀取設定檔 %s 失敗: %w", path, err)
    }
    // ...
    return nil
}
```

### 3. 拆解：使用 errors.As 取回自定義錯誤

```go
func handleError(err error) {
    var apiErr *APIError
    if errors.As(err, &apiErr) {
        // 成功取得 APIError，可以存取 Code
        fmt.Printf("API 錯誤碼: %d\n", apiErr.Code)
        return
    }
    // 其他錯誤
    fmt.Println("未知錯誤:", err)
}
```

### 4. 判斷：使用 errors.Is 比對特定錯誤

```go
var ErrNotFound = errors.New("找不到資源")

func findUser(id int) (*User, error) {
    // ...
    return nil, ErrNotFound
}

func main() {
    _, err := findUser(123)
    if errors.Is(err, ErrNotFound) {
        fmt.Println("使用者不存在")
    }
}
```

---

## 六、常見錯誤類型定義模式

### Sentinel Error (哨兵錯誤)

```go
var (
    ErrNotFound     = errors.New("not found")
    ErrUnauthorized = errors.New("unauthorized")
    ErrBadRequest   = errors.New("bad request")
)
```

### Error Type (錯誤類型)

```go
type ValidationError struct {
    Field   string
    Message string
}

func (e *ValidationError) Error() string {
    return fmt.Sprintf("欄位 %s 驗證失敗: %s", e.Field, e.Message)
}
```

### 選擇建議

| 情境 | 建議 |
|:-----|:-----|
| 簡單錯誤比對 | 用 Sentinel Error (`errors.Is`) |
| 需要攜帶額外資訊 | 用 Error Type (`errors.As`) |

---

## 七、Panic 與 Recover

### Panic：程式的「緊急煞車」

**用途**：處理不可恢復的錯誤，如程式邏輯錯誤。

> **原則**：一般業務邏輯不要用 panic，應該回傳 error。Panic 應保留給「不應該發生」的情況。
{: .warning }

```go
// 適合使用 panic 的情況
func MustParseConfig(path string) Config {
    cfg, err := ParseConfig(path)
    if err != nil {
        panic("設定檔解析失敗，程式無法啟動: " + err.Error())
    }
    return cfg
}

// 常見的 panic 情境
arr := []int{1, 2, 3}
_ = arr[10]  // panic: index out of range

var p *User
p.Name = "test"  // panic: nil pointer dereference
```

### Recover：捕捉 Panic

```go
func safeOperation() {
    defer func() {
        if r := recover(); r != nil {
            fmt.Println("捕捉到 panic:", r)
            // 可以在這裡做清理或記錄
        }
    }()

    // 可能會 panic 的操作
    riskyFunction()
}
```

### Panic vs Error 使用時機

| 情境 | 建議 | 原因 |
|:-----|:-----|:-----|
| 使用者輸入錯誤 | `error` | 預期內的錯誤，應優雅處理 |
| 檔案不存在 | `error` | 常見情況，呼叫者可處理 |
| 網路請求失敗 | `error` | 外部依賴的問題 |
| 陣列越界 (程式 bug) | `panic` | 程式邏輯錯誤 |
| nil 指標 (程式 bug) | `panic` | 程式邏輯錯誤 |
| 初始化失敗 (無法恢復) | `panic` | 程式無法正常運行 |

---

## 八、errors.Unwrap：拆解錯誤鏈

當錯誤被層層包裝後，可以用 `Unwrap` 取得原始錯誤。

```go
// 包裝錯誤
originalErr := errors.New("原始錯誤")
wrappedErr := fmt.Errorf("外層描述: %w", originalErr)
doubleWrapped := fmt.Errorf("最外層: %w", wrappedErr)

// 拆解錯誤
inner := errors.Unwrap(doubleWrapped)
fmt.Println(inner)  // 外層描述: 原始錯誤

original := errors.Unwrap(inner)
fmt.Println(original)  // 原始錯誤
```

> **提示**：實務上很少直接用 `Unwrap`，通常用 `errors.Is` 和 `errors.As`，它們會自動遍歷整條錯誤鏈。
{: .note }

---

## 九、HTTP 錯誤處理模式

### 實戰範例：RESTful API 錯誤處理

```go
// 定義 HTTP 錯誤
type HTTPError struct {
    Code    int    `json:"code"`
    Message string `json:"message"`
}

func (e *HTTPError) Error() string {
    return fmt.Sprintf("HTTP %d: %s", e.Code, e.Message)
}

// 常用錯誤
var (
    ErrBadRequest   = &HTTPError{Code: 400, Message: "請求格式錯誤"}
    ErrUnauthorized = &HTTPError{Code: 401, Message: "未授權"}
    ErrForbidden    = &HTTPError{Code: 403, Message: "禁止存取"}
    ErrNotFound     = &HTTPError{Code: 404, Message: "資源不存在"}
    ErrInternal     = &HTTPError{Code: 500, Message: "內部伺服器錯誤"}
)

// 統一錯誤處理
func handleError(w http.ResponseWriter, err error) {
    var httpErr *HTTPError
    if errors.As(err, &httpErr) {
        w.WriteHeader(httpErr.Code)
        json.NewEncoder(w).Encode(httpErr)
        return
    }
    // 未知錯誤視為 500
    w.WriteHeader(500)
    json.NewEncoder(w).Encode(ErrInternal)
}
```

---

## 十、最佳實踐總結

### Do's (建議做法)

| 實踐 | 說明 |
|:-----|:-----|
| 立即檢查錯誤 | 呼叫函式後馬上 `if err != nil` |
| 包裝錯誤加上下文 | 用 `fmt.Errorf("操作失敗: %w", err)` |
| 只在最上層記錄日誌 | 避免同一錯誤重複 log |
| 使用 Sentinel Error | 定義可比對的錯誤常數 |
| 自定義錯誤攜帶資訊 | 需要額外資訊時用 struct |

### Don'ts (避免做法)

| 避免 | 原因 |
|:-----|:-----|
| 忽略錯誤 `_, _ = f()` | 隱藏問題，導致難以 debug |
| 用 `panic` 處理業務錯誤 | `panic` 應保留給不可恢復的錯誤 |
| 每層都 log 錯誤 | 造成日誌重複、難以追蹤 |
| 回傳 `err.Error()` 字串 | 失去錯誤類型資訊，無法用 `Is`/`As` |
| 比較 `err.Error()` 字串 | 脆弱且容易出錯 |

### 完整範例：生產等級的錯誤處理

```go
package main

import (
    "errors"
    "fmt"
    "log"
)

// 定義錯誤類型
var ErrUserNotFound = errors.New("user not found")

type ValidationError struct {
    Field   string
    Message string
}

func (e *ValidationError) Error() string {
    return fmt.Sprintf("validation failed on %s: %s", e.Field, e.Message)
}

// 業務邏輯層
func GetUser(id int) (*User, error) {
    if id <= 0 {
        return nil, &ValidationError{Field: "id", Message: "must be positive"}
    }

    user, err := db.FindUser(id)
    if err != nil {
        if errors.Is(err, sql.ErrNoRows) {
            return nil, ErrUserNotFound
        }
        return nil, fmt.Errorf("query user %d: %w", id, err)
    }
    return user, nil
}

// API 處理層
func handleGetUser(w http.ResponseWriter, r *http.Request) {
    user, err := GetUser(id)
    if err != nil {
        var validErr *ValidationError
        switch {
        case errors.As(err, &validErr):
            respondError(w, 400, validErr.Message)
        case errors.Is(err, ErrUserNotFound):
            respondError(w, 404, "User not found")
        default:
            log.Printf("unexpected error: %v", err)  // 只在這裡 log
            respondError(w, 500, "Internal server error")
        }
        return
    }
    respondJSON(w, 200, user)
}
```

---

## 十一、常見面試題

### Q1：error 和 panic 的區別？
- **error**：預期可能發生的錯誤，透過回傳值傳遞，呼叫者負責處理
- **panic**：不可恢復的錯誤，會中斷正常流程，除非被 recover 捕捉

### Q2：什麼時候用 errors.Is？什麼時候用 errors.As？
- **errors.Is**：判斷錯誤鏈中是否包含特定的錯誤值 (Sentinel Error)
- **errors.As**：從錯誤鏈中取出特定類型的錯誤，以取得額外資訊

### Q3：為什麼要用 %w 而不是 %v 包裝錯誤？
- `%w` 會保留原始錯誤，讓 `errors.Is` 和 `errors.As` 可以穿透錯誤鏈
- `%v` 只是把錯誤轉成字串，失去類型資訊

```go
err := errors.New("original")

wrapped := fmt.Errorf("context: %w", err)
errors.Is(wrapped, err)  // true ✓

asString := fmt.Errorf("context: %v", err)
errors.Is(asString, err)  // false ✗
```

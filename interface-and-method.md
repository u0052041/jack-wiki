---
layout: default
title: Methods & Interfaces
nav_order: 6
---

# Go 進階筆記：Methods & Interfaces (物件與行為)
{: .no_toc }

## 目錄
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## 一、Methods (方法)

### 1. 核心觀念：沒有 Class，只有 Type

Go 沒有類別 (Class)，但你可以為任何自定義型別 (除了指標與 Interface 本身) 定義方法。

```go
type MyFloat float64

// 即使是基礎型別的別名，也能擁有方法
func (f MyFloat) Abs() float64 {
    if f < 0 {
        return float64(-f)
    }
    return float64(f)
}
```

### 2. 接收者對決：Value vs Pointer Receiver (關鍵)

#### (A) Value Receiver `func (v T) M()`
- **機制**：呼叫時會將物件複製 (Copy) 一份
- **限制**：方法內修改欄位無效 (只改到複製品)
- **適用**：小物件、不需要修改狀態、並行安全 (因為是副本)

#### (B) Pointer Receiver `func (v *T) M()` (推薦/主流)
- **機制**：傳遞記憶體地址
- **優點**：可修改狀態、避免大物件複製成本
- **慣例**：如果有一個方法用了 Pointer Receiver，建議該型別的所有方法都統一用 Pointer

```go
type User struct { Name string }

// 修改失敗：只改到副本
func (u User) BadChange() {
    u.Name = "Alice"
}

// 修改成功：直接操作記憶體
func (u *User) GoodChange() {
    u.Name = "Alice"
}
```

---

## 二、Interfaces (介面)

### 1. 隱式實作 (Implicit Implementation)

**Duck Typing**："If it walks like a duck..."

- 不需要寫 `implements`。只要一個型別實作了介面定義的所有方法，它就自動滿足該介面
- **解耦**：呼叫端只依賴 Interface，不依賴具體 Struct (方便 Mock 測試)

```go
type Reader interface {
    Read(p []byte) (n int, err error)
}

// 任何有 Read 方法的型別，都可以被視為 Reader
```

### 2. 介面的內部結構 (Tuple)

Interface 在 Runtime 其實是一對 `(Value, Type)`。

```go
var i I = t  // 內部結構：(數值=t的資料, 型別=T)
```

---

## 三、避坑指南 (Traps & Gotchas)

### 1. Nil Interface 的陷阱 (必考題)

**觀念**：Interface 只有在 `(Type=nil, Value=nil)` 時才等於 `nil`。

**地雷**：如果把一個「數值為 nil 的具體指標」賦值給 Interface，該 Interface **不是** nil。

```go
var t *User = nil
var i interface{} = t

// i 內部是 (Type=*User, Value=nil)
// 所以 i != nil !!!
if i == nil {
    fmt.Println("這行不會被執行")
} else {
    fmt.Println("陷阱：i 不是 nil，雖然它裡面裝的是 nil 指標")
}
```

### 2. 空介面 (`interface{}` 或 `any`)

**定義**：沒有任何方法要求的介面，所以任何型別都滿足它。

**用途**：處理未知型別 (如 `fmt.Println`、JSON 解析)。

**取值**：必須使用 Type Assertion。

```go
var i any = "hello"

// 安全取值 (Comma-ok idiom)
s, ok := i.(string)
if ok {
    fmt.Println(s)
}

// 危險寫法 (若型別錯誤會 Panic)
f := i.(float64)  // panic!
```

### 3. 業界建議 (Best Practices)

| 建議 | 說明 |
|:-----|:-----|
| 接受介面，回傳結構 | 讓呼叫者決定傳什麼實作進來，但你的函式回傳具體的型別以便操作 |
| 小介面 | 介面定義的方法越少越好 (如 `io.Reader` 只有一個方法)，越容易被重複利用 |

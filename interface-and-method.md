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

---

## 四、介面組合 (Interface Embedding)

### 組合多個介面

```go
type Reader interface {
    Read(p []byte) (n int, err error)
}

type Writer interface {
    Write(p []byte) (n int, err error)
}

// 組合介面
type ReadWriter interface {
    Reader
    Writer
}

// 任何同時實作 Read 和 Write 的型別都滿足 ReadWriter
```

### 標準庫常見組合

```go
// io 套件
type ReadCloser interface {
    Reader
    Closer
}

type WriteCloser interface {
    Writer
    Closer
}

type ReadWriteCloser interface {
    Reader
    Writer
    Closer
}
```

---

## 五、更多陷阱與注意事項

### 陷阱 1：Pointer Receiver 與 Interface

```go
type Printer interface {
    Print()
}

type Doc struct{ Name string }

func (d *Doc) Print() {  // Pointer Receiver
    fmt.Println(d.Name)
}

var p Printer

p = &Doc{Name: "A"}  // OK
p = Doc{Name: "B"}   // 編譯錯誤！Doc 沒有實作 Printer，只有 *Doc 實作了
```

> **規則**：如果方法使用 Pointer Receiver，只有指標型別 `*T` 實作介面，值型別 `T` 不算。
{: .important }

### 陷阱 2：介面值的比較

```go
var a, b interface{}

a = 1
b = 1
fmt.Println(a == b)  // true

a = []int{1}
b = []int{1}
fmt.Println(a == b)  // panic! slice 不可比較
```

> **注意**：介面值只有在底層型別可比較時才能用 `==`，否則會 panic。
{: .warning }

### 陷阱 3：隱藏的 nil 值

```go
func getError() error {
    var err *MyError = nil  // 具體型別的 nil
    return err  // 返回介面
}

if getError() != nil {
    fmt.Println("有錯誤！")  // 會執行！因為 error 介面不是 nil
}

// 解法：直接返回 nil
func getError() error {
    return nil  // 介面型別的 nil
}
```

---

## 六、Type Assertion vs Type Switch

### Type Assertion (類型斷言)

```go
var i interface{} = "hello"

// 方式 1：直接斷言 (危險)
s := i.(string)  // OK
n := i.(int)     // panic!

// 方式 2：Comma-ok (安全)
s, ok := i.(string)
if ok {
    fmt.Println(s)
}
```

### Type Switch (類型切換)

```go
func handle(i interface{}) {
    switch v := i.(type) {
    case string:
        fmt.Println("字串:", v)
    case int:
        fmt.Println("整數:", v)
    case nil:
        fmt.Println("nil")
    default:
        fmt.Printf("未知: %T\n", v)
    }
}
```

| 比較 | Type Assertion | Type Switch |
|:-----|:-----|:-----|
| 用途 | 確定知道類型時 | 多種可能類型時 |
| 安全性 | 需用 comma-ok | 內建安全 |
| 效能 | 略快 | 略慢 |

---

## 七、常見標準庫介面

### 必知介面

| 介面 | 方法 | 用途 |
|:-----|:-----|:-----|
| `io.Reader` | `Read([]byte) (int, error)` | 讀取資料 |
| `io.Writer` | `Write([]byte) (int, error)` | 寫入資料 |
| `io.Closer` | `Close() error` | 關閉資源 |
| `fmt.Stringer` | `String() string` | 自訂印出格式 |
| `error` | `Error() string` | 錯誤處理 |
| `sort.Interface` | `Len()`, `Less()`, `Swap()` | 排序 |

### Stringer 實用範例

```go
type User struct {
    Name string
    Age  int
}

func (u User) String() string {
    return fmt.Sprintf("%s (%d歲)", u.Name, u.Age)
}

user := User{"Alice", 30}
fmt.Println(user)  // Alice (30歲)
```

---

## 八、介面設計原則

### 1. 由使用者定義介面 (Consumer-side)

```go
// 錯誤：在套件中預先定義大介面
package mydb

type Database interface {
    Connect() error
    Query(sql string) (*Result, error)
    Exec(sql string) error
    Close() error
    // ... 20 個方法
}

// 正確：讓使用者定義需要的小介面
package myservice

type Querier interface {
    Query(sql string) (*Result, error)
}

func ProcessData(db Querier) {  // 只依賴需要的方法
    db.Query("SELECT ...")
}
```

### 2. 介面越小越好

```go
// Go 諺語：The bigger the interface, the weaker the abstraction.
// 介面越大，抽象越弱。

// 好：單一方法介面
type Reader interface {
    Read(p []byte) (n int, err error)
}

// 不好：臃腫介面
type FileHandler interface {
    Read() error
    Write() error
    Delete() error
    Copy() error
    Move() error
    // ...
}
```

---

## 九、常見面試題

### Q1：interface{} 和 any 的差別？
沒有差別，`any` 是 Go 1.18+ 引入的 `interface{}` 別名，讓程式碼更易讀。

### Q2：nil interface 和 interface with nil value 的差別？

```go
var i interface{} = nil           // nil interface
var p *int = nil; var j interface{} = p  // interface with nil value

i == nil  // true
j == nil  // false (type=*int, value=nil)
```

### Q3：如何判斷介面底層值是否為 nil？

```go
func isNil(i interface{}) bool {
    if i == nil {
        return true
    }
    v := reflect.ValueOf(i)
    return v.Kind() == reflect.Ptr && v.IsNil()
}
```

### Q4：Value Receiver 和 Pointer Receiver 該怎麼選？

| 情境 | 建議 |
|:-----|:-----|
| 需要修改 receiver | Pointer |
| struct 很大 | Pointer (避免複製) |
| struct 很小且唯讀 | Value |
| 一致性 | 如果有一個用 Pointer，全部都用 Pointer |

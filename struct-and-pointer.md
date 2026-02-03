---
layout: default
title: Struct & Pointer 基礎指南
nav_order: 2
---

# Go 進階筆記：Struct & Pointer 基礎指南
{: .no_toc }

Go 的核心資料結構與記憶體操作
{: .fs-6 .fw-300 }

## 目錄
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## 一、Struct (結構體)

### 基本定義與初始化

```go
// 定義結構體
type User struct {
    Name string
    Age  int
    Email string
}

// 初始化方式 1：零值
var u1 User  // {Name:"", Age:0, Email:""}

// 初始化方式 2：字面量 (推薦)
u2 := User{
    Name:  "Alice",
    Age:   25,
    Email: "alice@example.com",
}

// 初始化方式 3：省略欄位名 (不推薦，順序依賴)
u3 := User{"Bob", 30, "bob@example.com"}

// 初始化方式 4：部分欄位 (其他為零值)
u4 := User{Name: "Charlie"}  // Age=0, Email=""
```

> **建議**：總是使用欄位名初始化，避免順序依賴造成的 bug。
{: .note }

### 存取欄位

```go
u := User{Name: "Alice", Age: 25}

// 讀取
fmt.Println(u.Name)  // Alice

// 修改
u.Age = 26
```

### 匿名結構體 (Anonymous Struct)

```go
// 臨時使用，不需要定義型別
point := struct {
    X, Y int
}{10, 20}

// 常見用途：測試資料、JSON 回應
testCases := []struct {
    input    string
    expected int
}{
    {"hello", 5},
    {"world", 5},
}
```

### 結構體嵌入 (Embedding)

```go
type Address struct {
    City    string
    Country string
}

type Person struct {
    Name    string
    Address  // 嵌入，不是欄位名
}

p := Person{
    Name: "Alice",
    Address: Address{
        City:    "Taipei",
        Country: "Taiwan",
    },
}

// 可以直接存取嵌入的欄位 (promoted fields)
fmt.Println(p.City)     // Taipei (等同於 p.Address.City)
fmt.Println(p.Country)  // Taiwan
```

> **注意**：這不是繼承！是組合 (Composition)。Go 沒有繼承。
{: .warning }

---

## 二、Pointer (指標)

### 基本概念

```go
x := 10
p := &x  // p 是指向 x 的指標，類型是 *int

fmt.Println(p)   // 0xc0000140a8 (記憶體地址)
fmt.Println(*p)  // 10 (解引用，取得值)

*p = 20          // 透過指標修改值
fmt.Println(x)   // 20
```

### 指標 vs 值

```go
// 值傳遞：複製一份
func doubleValue(n int) {
    n = n * 2  // 只改到副本
}

// 指標傳遞：傳地址
func doublePointer(n *int) {
    *n = *n * 2  // 改到原本的值
}

x := 10
doubleValue(x)
fmt.Println(x)  // 10 (沒變)

doublePointer(&x)
fmt.Println(x)  // 20 (被改了)
```

### new 與 make 的區別

```go
// new：分配記憶體，回傳指標，值為零值
p := new(int)      // *int，指向 0
u := new(User)     // *User，指向 User{}

// make：只用於 slice, map, channel，回傳初始化後的值 (非指標)
s := make([]int, 5)      // []int
m := make(map[string]int) // map[string]int
```

| 函式 | 適用類型 | 回傳值 | 用途 |
|:-----|:-----|:-----|:-----|
| `new(T)` | 任何類型 | `*T` (指向零值) | 分配記憶體 |
| `make(T)` | slice, map, channel | `T` (已初始化) | 建立並初始化 |

---

## 三、Struct 與 Pointer 的結合

### 指向 Struct 的指標

```go
u := &User{Name: "Alice", Age: 25}  // u 是 *User

// Go 的語法糖：自動解引用
fmt.Println(u.Name)   // Alice (等同於 (*u).Name)
u.Age = 26            // 等同於 (*u).Age = 26
```

### 什麼時候用指標？

| 情境 | 建議 | 原因 |
|:-----|:-----|:-----|
| 需要修改 struct | `*T` | 值傳遞會複製，改不到原本的 |
| struct 很大 | `*T` | 避免複製成本 |
| struct 很小且唯讀 | `T` | 複製成本低，更安全 |
| 需要表示「空」| `*T` | 指標可以是 `nil` |
| 作為 method receiver | 通常用 `*T` | 一致性，且可修改 |

### 常見模式：Constructor 函式

```go
func NewUser(name string, age int) *User {
    return &User{
        Name: name,
        Age:  age,
    }
}

// 使用
u := NewUser("Alice", 25)
```

---

## 四、常見陷阱

### 陷阱 1：nil 指標解引用

> **嚴重**：這是 Go 程式 panic 的最常見原因之一！
{: .important }

```go
var u *User  // nil 指標

fmt.Println(u.Name)  // panic: runtime error: invalid memory address

// 解法：檢查 nil
if u != nil {
    fmt.Println(u.Name)
}
```

### 陷阱 2：迴圈中取指標

```go
users := []User{
    {Name: "Alice"},
    {Name: "Bob"},
}

// 錯誤：所有指標都指向同一個位置
var ptrs []*User
for _, u := range users {
    ptrs = append(ptrs, &u)  // u 是迴圈變數，地址固定
}
// ptrs[0].Name == ptrs[1].Name == "Bob"

// 正確做法 1：用索引
for i := range users {
    ptrs = append(ptrs, &users[i])
}

// 正確做法 2：建立副本
for _, u := range users {
    u := u  // 區域變數
    ptrs = append(ptrs, &u)
}
```

### 陷阱 3：Struct 比較

```go
type Point struct {
    X, Y int
}

p1 := Point{1, 2}
p2 := Point{1, 2}
fmt.Println(p1 == p2)  // true (所有欄位可比較)

// 但如果有不可比較的欄位...
type Data struct {
    Values []int  // slice 不可比較
}

d1 := Data{[]int{1, 2}}
d2 := Data{[]int{1, 2}}
// fmt.Println(d1 == d2)  // 編譯錯誤！

// 解法：使用 reflect.DeepEqual
import "reflect"
fmt.Println(reflect.DeepEqual(d1, d2))  // true
```

### 陷阱 4：空 Struct 的用途

```go
// struct{} 佔用 0 bytes，常用於：

// 1. 實作 Set
seen := make(map[string]struct{})
seen["apple"] = struct{}{}

// 2. 信號 channel
done := make(chan struct{})
close(done)  // 發送完成信號
```

---

## 五、Struct Tags

### JSON Tags

```go
type User struct {
    ID        int    `json:"id"`
    Name      string `json:"name"`
    Email     string `json:"email,omitempty"`  // 空值時省略
    Password  string `json:"-"`                 // 永遠忽略
    CreatedAt string `json:"created_at"`
}

u := User{ID: 1, Name: "Alice"}
data, _ := json.Marshal(u)
// {"id":1,"name":"Alice"}  (Email 和 Password 被省略)
```

### 常見 Tag 選項

| Tag | 說明 |
|:-----|:-----|
| `json:"name"` | 指定 JSON key 名稱 |
| `json:"name,omitempty"` | 零值時省略此欄位 |
| `json:"-"` | 忽略此欄位 |
| `json:",string"` | 數字轉為字串 |

### 其他常見 Tags

```go
type Model struct {
    ID   int    `json:"id" db:"id" validate:"required"`
    Name string `json:"name" db:"user_name" validate:"min=2,max=50"`
}
```

---

## 六、值傳遞 vs 引用語意

### Go 只有值傳遞！

```go
// 所有參數都是「複製」傳入
func modify(u User) {
    u.Name = "Modified"  // 改的是副本
}

u := User{Name: "Original"}
modify(u)
fmt.Println(u.Name)  // Original (沒變)
```

### 「看起來像」引用的類型

```go
// Slice, Map, Channel 傳遞時複製的是 header/descriptor
// 但底層資料是共享的

func modifySlice(s []int) {
    s[0] = 999  // 會影響原 slice
}

nums := []int{1, 2, 3}
modifySlice(nums)
fmt.Println(nums)  // [999 2 3]
```

| 類型 | 傳參行為 | 修改是否影響原值 |
|:-----|:-----|:-----|
| int, string, bool | 複製值 | 否 |
| struct | 複製整個 struct | 否 |
| *T (指標) | 複製地址 | 是 |
| slice | 複製 header | 修改元素：是 / append：看情況 |
| map | 複製 descriptor | 是 |
| channel | 複製 descriptor | 是 |

---

## 七、常見面試題

### Q1：new 和 make 的區別？
- `new(T)` 回傳 `*T`，指向零值
- `make(T)` 只用於 slice/map/channel，回傳初始化後的 `T`

### Q2：Struct 可以比較嗎？
只有當所有欄位都是可比較類型時才可以。包含 slice、map、function 的 struct 不能用 `==` 比較。

### Q3：以下程式碼輸出什麼？

```go
type T struct{ x int }
func (t T) Set(n int)  { t.x = n }
func (t *T) SetP(n int) { t.x = n }

t := T{x: 1}
t.Set(10)
fmt.Println(t.x)  // ?

t.SetP(20)
fmt.Println(t.x)  // ?
```

**答案**：`1` 和 `20`
- `Set` 是 value receiver，修改的是副本
- `SetP` 是 pointer receiver，修改的是原值

### Q4：為什麼 slice 傳參可以修改原值，但 append 可能不行？
- 修改元素：透過共享的底層陣列，會影響原值
- append：如果觸發擴容，會建立新的底層陣列，不影響原 slice

```go
func appendItem(s []int) {
    s = append(s, 4)  // 如果擴容，s 指向新陣列
}

nums := make([]int, 3, 3)  // len=3, cap=3
appendItem(nums)
fmt.Println(nums)  // [0 0 0] (沒有 4！)
```

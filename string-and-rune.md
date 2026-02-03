---
layout: default
title: String & Rune 字串處理
nav_order: 3
---

# Go 進階筆記：String & Rune 字串處理
{: .no_toc }

中文處理必學，byte vs rune 的陷阱
{: .fs-6 .fw-300 }

## 目錄
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## 一、字串的本質

### 字串是不可變的 (Immutable)

```go
s := "hello"
// s[0] = 'H'  // 編譯錯誤！不能修改

// 要修改必須轉換
b := []byte(s)
b[0] = 'H'
s = string(b)  // "Hello"
```

### 字串底層是 []byte

```go
s := "hello"
fmt.Println(len(s))  // 5 (bytes)

// 可以用索引存取 (得到 byte)
fmt.Println(s[0])         // 104 (byte 值)
fmt.Printf("%c\n", s[0])  // h (字元)
```

---

## 二、Byte vs Rune (關鍵！)

### 處理中文的陷阱

> **嚴重**：這是處理中文時最常見的 bug！
{: .important }

```go
s := "你好"

// 錯誤認知：以為 len 是字元數
fmt.Println(len(s))  // 6 (不是 2！)

// 原因：中文字在 UTF-8 佔 3 bytes
// "你" = 3 bytes, "好" = 3 bytes, 共 6 bytes
```

### byte vs rune

| 類型 | 說明 | 大小 |
|:-----|:-----|:-----|
| `byte` | `uint8` 的別名，表示一個位元組 | 1 byte |
| `rune` | `int32` 的別名，表示一個 Unicode 碼點 | 4 bytes |

```go
s := "你好"

// 遍歷 byte (錯誤方式處理中文)
for i := 0; i < len(s); i++ {
    fmt.Printf("%c ", s[i])  // ä ½ å ¥ ½ (亂碼)
}

// 遍歷 rune (正確方式)
for _, r := range s {
    fmt.Printf("%c ", r)  // 你 好
}
```

### 取得字元數量

```go
s := "Hello 你好"

len(s)                    // 12 (bytes)
len([]rune(s))            // 8 (字元數)
utf8.RuneCountInString(s) // 8 (字元數，更高效)
```

---

## 三、字串遍歷

### 三種方式比較

```go
s := "Go你好"

// 方式 1：索引遍歷 (byte)
for i := 0; i < len(s); i++ {
    fmt.Printf("byte[%d] = %d\n", i, s[i])
}
// byte[0]=71, byte[1]=111, byte[2]=228, ...

// 方式 2：range 遍歷 (rune) - 推薦
for i, r := range s {
    fmt.Printf("index=%d, rune=%c\n", i, r)
}
// index=0 rune=G, index=1 rune=o, index=2 rune=你, index=5 rune=好

// 方式 3：轉換為 []rune
runes := []rune(s)
for i, r := range runes {
    fmt.Printf("index=%d, rune=%c\n", i, r)
}
// index=0 rune=G, index=1 rune=o, index=2 rune=你, index=3 rune=好
```

> **注意**：range 的 index 是 byte 位置，不是字元位置！
{: .warning }

---

## 四、字串操作

### 常用 strings 套件函式

```go
import "strings"

s := "Hello, World!"

// 查找
strings.Contains(s, "World")     // true
strings.HasPrefix(s, "Hello")    // true
strings.HasSuffix(s, "!")        // true
strings.Index(s, "o")            // 4 (第一個 o 的位置)
strings.LastIndex(s, "o")        // 8 (最後一個 o 的位置)
strings.Count(s, "l")            // 3

// 分割與合併
strings.Split("a,b,c", ",")      // ["a", "b", "c"]
strings.Join([]string{"a","b"}, "-")  // "a-b"

// 修改
strings.ToUpper(s)               // "HELLO, WORLD!"
strings.ToLower(s)               // "hello, world!"
strings.TrimSpace("  hi  ")      // "hi"
strings.Trim("!!hi!!", "!")      // "hi"
strings.Replace(s, "o", "0", -1) // "Hell0, W0rld!" (-1 = 全部替換)
strings.ReplaceAll(s, "o", "0")  // 同上 (Go 1.12+)

// 重複
strings.Repeat("ab", 3)          // "ababab"
```

### 字串與數字轉換

```go
import "strconv"

// 字串 → 數字
i, err := strconv.Atoi("123")           // int, error
i64, err := strconv.ParseInt("123", 10, 64)  // int64
f, err := strconv.ParseFloat("3.14", 64)     // float64
b, err := strconv.ParseBool("true")          // bool

// 數字 → 字串
s := strconv.Itoa(123)                  // "123"
s := strconv.FormatInt(123, 10)         // "123" (base 10)
s := strconv.FormatFloat(3.14, 'f', 2, 64)  // "3.14"
s := fmt.Sprintf("%d", 123)             // "123" (萬用但較慢)
```

---

## 五、字串拼接效能

### 各種方式比較

```go
// 方式 1：+ 運算子 (小量 OK，大量慢)
s := "a" + "b" + "c"

// 方式 2：fmt.Sprintf (靈活但慢)
s := fmt.Sprintf("%s %s", "hello", "world")

// 方式 3：strings.Join (適合 slice)
s := strings.Join([]string{"a", "b", "c"}, "")

// 方式 4：strings.Builder (大量拼接最快)
var b strings.Builder
for i := 0; i < 1000; i++ {
    b.WriteString("hello")
}
s := b.String()

// 方式 5：bytes.Buffer (需要同時處理 byte)
var buf bytes.Buffer
buf.WriteString("hello")
buf.WriteByte(' ')
buf.WriteString("world")
s := buf.String()
```

### 效能排名 (大量拼接)

| 方式 | 效能 | 適用場景 |
|:-----|:-----|:-----|
| `strings.Builder` | 最快 | 大量拼接 |
| `bytes.Buffer` | 快 | 需要 byte 操作 |
| `strings.Join` | 快 | 已有 slice |
| `+` | 慢 | 少量拼接 |
| `fmt.Sprintf` | 最慢 | 需要格式化 |

> **原則**：少量用 `+`，大量用 `strings.Builder`。
{: .note }

---

## 六、常見陷阱

### 陷阱 1：字串切片是 byte 切片

```go
s := "你好世界"

// 錯誤：按 byte 切片
fmt.Println(s[:3])  // "你" (剛好 3 bytes，運氣好)
fmt.Println(s[:4])  // 亂碼！(切到「好」的一半)

// 正確：先轉 rune
runes := []rune(s)
fmt.Println(string(runes[:2]))  // "你好"
```

### 陷阱 2：修改字串中的字元

```go
s := "hello"

// 錯誤：字串不可變
// s[0] = 'H'  // 編譯錯誤

// 正確：轉換後修改
b := []byte(s)
b[0] = 'H'
s = string(b)

// 或用 strings.Builder
var sb strings.Builder
sb.WriteByte('H')
sb.WriteString(s[1:])
s = sb.String()
```

### 陷阱 3：空字串判斷

```go
s := ""

// 兩種方式都可以
if s == "" { }
if len(s) == 0 { }

// 但要小心空白字串
s = "   "
if s == "" { }           // false
if len(s) == 0 { }       // false
if strings.TrimSpace(s) == "" { }  // true
```

### 陷阱 4：字串比較

```go
// 字串可以直接用 == 比較
s1 := "hello"
s2 := "hello"
fmt.Println(s1 == s2)  // true

// 但大小寫敏感
s1 := "Hello"
s2 := "hello"
fmt.Println(s1 == s2)  // false
fmt.Println(strings.EqualFold(s1, s2))  // true (忽略大小寫)
```

---

## 七、實用範例

### 反轉字串 (支援中文)

```go
func reverseString(s string) string {
    runes := []rune(s)
    for i, j := 0, len(runes)-1; i < j; i, j = i+1, j-1 {
        runes[i], runes[j] = runes[j], runes[i]
    }
    return string(runes)
}

reverseString("Hello")   // "olleH"
reverseString("你好世界") // "界世好你"
```

### 截取前 N 個字元

```go
func truncate(s string, n int) string {
    runes := []rune(s)
    if len(runes) <= n {
        return s
    }
    return string(runes[:n]) + "..."
}

truncate("Hello World", 5)  // "Hello..."
truncate("你好世界", 2)      // "你好..."
```

### 統計字元出現次數

```go
func countRunes(s string) map[rune]int {
    counts := make(map[rune]int)
    for _, r := range s {
        counts[r]++
    }
    return counts
}
```

### 駝峰轉蛇底

```go
func camelToSnake(s string) string {
    var result strings.Builder
    for i, r := range s {
        if unicode.IsUpper(r) {
            if i > 0 {
                result.WriteByte('_')
            }
            result.WriteRune(unicode.ToLower(r))
        } else {
            result.WriteRune(r)
        }
    }
    return result.String()
}

camelToSnake("getUserName")  // "get_user_name"
```

---

## 八、常見面試題

### Q1：string 和 []byte 的區別？

| 特性 | string | []byte |
|:-----|:-----|:-----|
| 可變性 | 不可變 | 可變 |
| 底層 | 指標 + 長度 | 指標 + 長度 + 容量 |
| 用途 | 文字處理 | 二進位資料 |

### Q2：為什麼 range 字串得到的 index 不連續？

因為 range 遍歷的是 rune，index 是每個 rune 在原字串中的 byte 位置。中文字佔 3 bytes，所以 index 會跳 3。

### Q3：如何高效拼接大量字串？

使用 `strings.Builder`，它內部使用 `[]byte` 並且會預分配空間，避免頻繁的記憶體分配。

### Q4：`len("你好")` 的結果是？

`6`，因為 `len()` 返回的是 byte 數量，每個中文字在 UTF-8 編碼下佔 3 bytes。

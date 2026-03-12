---
layout: default
title: Slice & Array 終極實戰指南
parent: Golang 筆記
nav_order: 3
---

# Golang Slice & Array 終極實戰指南
{: .no_toc }

Python 對照 & 全語法收錄
{: .fs-6 .fw-300 }

## 目錄
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## 1. 核心觀念：Python vs Go (轉職必看)

### 賦值 (`=`)

| 語言 | 行為 |
|:-----|:-----|
| Python | `b = a` 是引用 (Reference) |
| Go Array | `b = a` 是複製值 (改 b 不影響 a) |
| Go Slice | `b = a` 是複製票根 (共享底層，改 b 會影響 a) |

### 切片 (`[:]`)

| 語言 | 行為 |
|:-----|:-----|
| Python | `b = a[:]` 是複製 (Shallow Copy) |
| Go | `b = a[:]` 是共享視窗 (View)，改 b 會影響 a |

---

## 2. 初始化：Nil vs Empty

```go
// Nil Slice (JSON: null)，可直接 append
var s []int

// Empty Slice (JSON: [])
s := []int{}

// Pre-alloc (推薦！效能關鍵)
s := make([]int, 0, 100)
```

---

## 3. 複製 (Clone) 的三大流派

### 流派 A (嚴謹/通用)
```go
b := append(a[:0:0], a...)
```
- 優點：強制分配記憶體、自動推斷型別、Nil 保持 Nil

### 流派 B (簡潔)
```go
b := append([]int(nil), a...)
```

### 流派 C (傳統)
```go
b := make([]T, len(a))
copy(b, a)
```

---

## 4. 常見語法與操作 (Idioms)

```go
// 清空 (Reuse)：保留容量，極快
s = s[:0]

// 釋放 (GC)：釋放記憶體
s = nil

// 刪除 (Delete at i)
s = append(s[:i], s[i+1:]...)

// 插入 (Insert at i)
s = append(s[:i], append([]int{x}, s[i:]...)...)
```

### 過濾 (Filter)
```go
n := 0
for _, x := range s {
    if keep(x) {
        s[n] = x
        n++
    }
}
s = s[:n]
```

### Stack/Queue
```go
// Push
s = append(s, x)

// Pop
x, s = s[len(s)-1], s[:len(s)-1]

// Shift (注意記憶體洩漏)
x, s = s[0], s[1:]
```

---

## 5. 進階語法 (少見但要懂)

### Full Slice Expression
```go
s[low:high:max]
```
- 用來限制容量 (Cap)，強制後續 append 觸發搬家
- 例：`s[:0:0]` (Cap=0), `s[2:4:4]` (Cap=4-2=2)

### Copy 回傳值
```go
n := copy(dst, src)  // 回傳複製成功的數量
```

---

## 6. Go 1.21+ `slices` 套件 (現代寫法)

```go
import "slices"

slices.Sort(s)
slices.Reverse(s)
slices.Contains(s, val)
slices.Delete(s, i, j)
slices.Clone(s)  // 底層就是用流派 A
```

---

## 7. 避坑指南

| 陷阱 | 說明 | 解法 |
|:-----|:-----|:-----|
| 迴圈陷阱 | 修改時用 `for _, v` 會失效 | 用 `for i := range s` |
| 記憶體洩漏 | 大陣列切小片 `small = big[:2]` 會卡死 GC | 用 `copy` 或 `append` 複製出來 |
| Append 擴容 | cap < 256 時翻倍 (地址改變) | 注意 cap 夠時原地改 (地址不變) |

### 陷阱 1：迴圈變數修改無效

```go
s := []int{1, 2, 3}

// 錯誤：v 是複製品，修改無效
for _, v := range s {
    v *= 2  // 沒有改到原 slice！
}
fmt.Println(s)  // [1 2 3]

// 正確：用索引直接改
for i := range s {
    s[i] *= 2
}
fmt.Println(s)  // [2 4 6]
```

### 陷阱 2：迴圈變數捕獲 (閉包/goroutine)

> **嚴重**：這是 Go 最常見的 bug 之一！
{: .important }

```go
// 錯誤：所有 goroutine 都會印出 3
s := []int{1, 2, 3}
for _, v := range s {
    go func() {
        fmt.Println(v)  // 捕獲的是同一個變數 v
    }()
}
// 可能輸出：3 3 3

// 正確做法 1：傳參數
for _, v := range s {
    go func(val int) {
        fmt.Println(val)
    }(v)
}

// 正確做法 2：區域變數 (Go 1.22+ 已修復此問題)
for _, v := range s {
    v := v  // 建立區域副本
    go func() {
        fmt.Println(v)
    }()
}
```

### 陷阱 3：Append 可能改變底層陣列

```go
a := []int{1, 2, 3}
b := a[:2]  // b 和 a 共享底層

b = append(b, 99)  // cap 夠，原地修改
fmt.Println(a)  // [1 2 99] <- a 也被改了！

// 解法：用 full slice expression 限制 cap
b := a[:2:2]  // cap=2，強制 append 時分配新記憶體
b = append(b, 99)
fmt.Println(a)  // [1 2 3] <- a 不受影響
```

### 陷阱 4：記憶體洩漏 (大切小)

```go
// 錯誤：small 仍引用 big 的底層陣列
big := make([]byte, 1<<20)  // 1MB
small := big[:10]  // 只用 10 bytes，但 1MB 無法被 GC

// 正確：複製出來
small := make([]byte, 10)
copy(small, big[:10])
// 或
small := append([]byte(nil), big[:10]...)
```

### 陷阱 5：Nil Slice vs Empty Slice

```go
var nilSlice []int          // nil
emptySlice := []int{}       // not nil, but empty

// 功能上相同
len(nilSlice) == 0          // true
len(emptySlice) == 0        // true
nilSlice = append(nilSlice, 1)  // OK

// JSON 序列化不同！
json.Marshal(nilSlice)      // null
json.Marshal(emptySlice)    // []
```

---

## 8. Append 擴容機制

```go
// 擴容規則 (Go 1.18+)
// - cap < 256: 容量翻倍
// - cap >= 256: 增加約 25% + 192

s := make([]int, 0)
for i := 0; i < 10; i++ {
    s = append(s, i)
    fmt.Printf("len=%d cap=%d\n", len(s), cap(s))
}
// len=1 cap=1
// len=2 cap=2
// len=3 cap=4
// len=4 cap=4
// len=5 cap=8
// ...
```

> **效能提示**：如果預先知道大小，用 `make([]T, 0, size)` 預分配可避免多次擴容。
{: .note }

---

## 9. 多維 Slice

```go
// 建立 3x4 的二維 slice
rows, cols := 3, 4
matrix := make([][]int, rows)
for i := range matrix {
    matrix[i] = make([]int, cols)
}

// 存取
matrix[1][2] = 5
```

> **注意**：Go 的多維 slice 每行是獨立的 slice，長度可以不同 (Jagged Array)。
{: .note }

---

## 10. 常見面試題

### Q1：Array 和 Slice 的區別？

| 特性 | Array | Slice |
|:-----|:-----|:-----|
| 長度 | 固定，編譯時確定 | 動態可變 |
| 傳參 | 複製整個陣列 | 複製 header (24 bytes) |
| 比較 | 可以用 `==` | 不能用 `==` |
| 宣告 | `[3]int` | `[]int` |

### Q2：Slice 的底層結構？

```go
type slice struct {
    array unsafe.Pointer  // 指向底層陣列
    len   int             // 長度
    cap   int             // 容量
}
// 共 24 bytes (64-bit 系統)
```

### Q3：以下程式碼輸出什麼？

```go
a := []int{1, 2, 3, 4, 5}
b := a[1:3]
b[0] = 99
fmt.Println(a)
```
**答案**：`[1 99 3 4 5]` — b 和 a 共享底層陣列

### Q4：如何安全地複製 slice？
使用 `copy` 或 `append([]T(nil), s...)`，確保底層陣列獨立

---
layout: default
title: Slice & Array 終極實戰指南
nav_order: 2
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

---
layout: default
title: Map 深度攻略
nav_order: 3
---

# Golang Map 深度攻略
{: .no_toc }

GC、巢狀與 Struct Key
{: .fs-6 .fw-300 }

## 目錄
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## 1. 記憶體與 GC 優化 (關鍵)

### 效能瓶頸
Map 的 Bucket 空間固定。若 Value 是大結構 (如 `[128]byte` 以上)：
- 擴容時搬運成本高
- `delete` 後 Bucket 佔用的記憶體不會歸還給 OS

### 優化方案：存指標
```go
// 使用指標存大結構
map[Key]*LargeStruct
```

**原理**：Bucket 內只存 8-byte 指標

**好處**：
- 刪除 Key 後，GC 能真正回收外部的大塊記憶體
- 擴容搬運極快

### 選擇建議

| 情境 | 建議 |
|:-----|:-----|
| Value 很大 | 存指標，避免複製成本 |
| Value 很小且數量多 | 存數值，減少 GC 掃描壓力 |

---

## 2. 結構對決：巢狀 vs Struct Key

### (A) 巢狀 Map
```go
map[Region]map[Date]int
```

**缺點 (Pain Points)**：
- 易崩潰：內層 Map 預設為 `nil`，寫入前必須檢查
  ```go
  if m[r] == nil {
      m[r] = make(map[Date]int)
  }
  ```
- 維護難：多層 `if` 判斷導致程式碼冗長

**優點**：
- 可針對第一層 Key (如 Region) 進行整批刪除或遍歷

### (B) Struct Key (推薦)
```go
type StatKey struct {
    Region string
    Date   string
}

map[StatKey]int
```

**優點**：
- 一行流：利用零值特性，直接 `m[StatKey{...}]++`，不需初始化
- 快：扁平化結構，減少指標跳轉 (Pointer Chasing)

**缺點**：
- 無法依特定維度 (如「所有 Date」) 進行局部遍歷

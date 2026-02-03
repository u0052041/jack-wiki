---
layout: default
title: 閉包核心與實戰
nav_order: 5
---

# Golang 閉包 (Closure) 核心與實戰
{: .no_toc }

## 目錄
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## 1. 核心觀念

**定義**：函式 + 該函式引用的外部變數 (Captured Environment)

**底層機制**：被捕獲的變數會經過逃逸分析 (Escape Analysis)，從 Stack 搬移到 Heap，確保函式執行完後變數依然存在且狀態獨立。

---

## 2. 簡單範例：狀態隔離 (Counter)

**目的**：取代全域變數，確保每個計數器互相獨立。

```go
func NewCounter() func() int {
    i := 0  // 私有變數 (被藏起來)
    return func() int {
        i++
        return i
    }
}

// 使用範例
c1 := NewCounter()
c1()  // -> 1
c1()  // -> 2

c2 := NewCounter()
c2()  // -> 1 (與 c1 互不影響)
```

---

## 3. 實戰範例：Middleware / 工廠模式

**場景**：在 Web Framework (如 Gin/Echo) 中，用閉包鎖定 Config 或權限設定。

```go
// 工廠：鎖定 "targetRole"
func RequireRole(targetRole string) func(User) bool {
    return func(u User) bool {
        // 閉包捕獲了 targetRole
        return u.Role == targetRole
    }
}

// 實戰：建立專用檢查器
checkAdmin := RequireRole("admin")
checkEditor := RequireRole("editor")

if checkAdmin(currentUser) {
    // 執行管理員操作
}
```

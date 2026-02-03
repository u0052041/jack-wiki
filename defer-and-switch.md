---
layout: default
title: Defer & Switch 語法範例全集
nav_order: 4
---

# Go 進階筆記：Defer & Switch 語法範例全集
{: .no_toc }

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

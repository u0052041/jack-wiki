---
layout: default
title: Map 深度攻略
nav_order: 4
---

# Golang Map 深度攻略
{: .no_toc }

從基礎到進階，涵蓋 GC 優化、併發安全、常見陷阱
{: .fs-6 .fw-300 }

## 目錄
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## 1. Map 基礎

### 宣告與初始化

```go
// 方式 1：var 宣告 (nil map，只能讀不能寫)
var m map[string]int
fmt.Println(m == nil)  // true
// m["key"] = 1        // panic: assignment to entry in nil map

// 方式 2：make 初始化 (推薦)
m := make(map[string]int)
m["apple"] = 5

// 方式 3：字面量初始化
m := map[string]int{
    "apple":  5,
    "banana": 3,
}

// 方式 4：make 並指定容量 (效能優化)
m := make(map[string]int, 100)  // 預分配空間，減少擴容
```

> **重點**：`var` 宣告的 map 是 `nil`，必須用 `make` 初始化後才能寫入。
{: .warning }

### 基本操作

```go
m := make(map[string]int)

// 新增/更新
m["apple"] = 5
m["apple"] = 10  // 覆蓋

// 讀取
count := m["apple"]       // 10
missing := m["orange"]    // 0 (零值，不存在也不會 panic)

// 刪除
delete(m, "apple")
delete(m, "notexist")     // 刪除不存在的 key 不會 panic

// 長度
len(m)
```

### Comma-ok 慣用法 (檢查 Key 是否存在)

```go
m := map[string]int{"apple": 0}

// 錯誤方式：無法區分「不存在」和「值為零值」
count := m["apple"]   // 0
count := m["banana"]  // 0 (也是 0，無法區分！)

// 正確方式：comma-ok idiom
if count, ok := m["apple"]; ok {
    fmt.Println("存在，值為:", count)
} else {
    fmt.Println("不存在")
}

// 只檢查存在性
if _, ok := m["banana"]; !ok {
    fmt.Println("banana 不存在")
}
```

> **注意**：當 value 可能為零值 (0, "", false, nil) 時，務必使用 comma-ok 來判斷。
{: .note }

---

## 2. Map 遍歷

### 基本遍歷

```go
m := map[string]int{"a": 1, "b": 2, "c": 3}

// 遍歷 key 和 value
for key, value := range m {
    fmt.Printf("%s: %d\n", key, value)
}

// 只遍歷 key
for key := range m {
    fmt.Println(key)
}

// 只遍歷 value
for _, value := range m {
    fmt.Println(value)
}
```

> **重要**：Map 遍歷順序是隨機的！每次執行順序可能不同，這是 Go 刻意設計的。
{: .important }

### 有序遍歷

```go
import "sort"

m := map[string]int{"c": 3, "a": 1, "b": 2}

// 步驟 1：取出所有 key
keys := make([]string, 0, len(m))
for k := range m {
    keys = append(keys, k)
}

// 步驟 2：排序 key
sort.Strings(keys)

// 步驟 3：依序存取
for _, k := range keys {
    fmt.Printf("%s: %d\n", k, m[k])
}
// 輸出：a: 1, b: 2, c: 3
```

---

## 3. 記憶體與 GC 優化 (關鍵)

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

## 4. 結構對決：巢狀 vs Struct Key

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

---

## 5. 併發安全 (重要)

### Map 不是併發安全的

> **嚴重**：多個 goroutine 同時讀寫同一個 map 會導致 `fatal error: concurrent map writes`，程式直接崩潰！
{: .important }

```go
// 錯誤示範：會 panic
m := make(map[int]int)

go func() {
    for i := 0; i < 1000; i++ {
        m[i] = i  // 寫
    }
}()

go func() {
    for i := 0; i < 1000; i++ {
        _ = m[i]  // 讀
    }
}()
// fatal error: concurrent map read and map write
```

### 解法 1：sync.RWMutex (推薦)

```go
type SafeMap struct {
    mu sync.RWMutex
    m  map[string]int
}

func (s *SafeMap) Get(key string) (int, bool) {
    s.mu.RLock()         // 讀鎖 (允許多個讀)
    defer s.mu.RUnlock()
    val, ok := s.m[key]
    return val, ok
}

func (s *SafeMap) Set(key string, val int) {
    s.mu.Lock()          // 寫鎖 (獨佔)
    defer s.mu.Unlock()
    s.m[key] = val
}

func (s *SafeMap) Delete(key string) {
    s.mu.Lock()
    defer s.mu.Unlock()
    delete(s.m, key)
}
```

### 解法 2：sync.Map (內建)

```go
var m sync.Map

// 存
m.Store("apple", 5)

// 取
if val, ok := m.Load("apple"); ok {
    fmt.Println(val.(int))  // 需要類型斷言
}

// 取或存 (不存在則存入)
actual, loaded := m.LoadOrStore("banana", 3)
// loaded=false 表示是新存入的

// 刪除
m.Delete("apple")

// 遍歷
m.Range(func(key, value any) bool {
    fmt.Printf("%v: %v\n", key, value)
    return true  // 繼續遍歷
})
```

### sync.Map vs RWMutex 選擇

| 情境 | 建議 |
|:-----|:-----|
| 讀多寫少 | `sync.Map` (內部優化，讀不需加鎖) |
| 讀寫均衡 | `sync.RWMutex` |
| 需要遍歷或批量操作 | `sync.RWMutex` (sync.Map 遍歷效能差) |
| Key 類型需要強型別 | `sync.RWMutex` (sync.Map 用 any) |

---

## 6. 常見陷阱與避坑

### 陷阱 1：nil map 寫入 panic

```go
var m map[string]int
m["key"] = 1  // panic: assignment to entry in nil map

// 解法：先初始化
m = make(map[string]int)
m["key"] = 1  // OK
```

### 陷阱 2：遍歷時新增/刪除

```go
m := map[int]int{1: 1, 2: 2, 3: 3}

// 遍歷時刪除：安全，但行為可能不如預期
for k := range m {
    if k == 2 {
        delete(m, k)  // 可以，但被刪的 key 可能還會被遍歷到
    }
}

// 遍歷時新增：不建議
for k := range m {
    m[k+10] = k  // 新增的 key 可能會也可能不會被遍歷到
}
```

> **建議**：如需遍歷時修改，先收集要處理的 key，遍歷結束後再修改。
{: .note }

```go
// 安全做法
toDelete := []int{}
for k, v := range m {
    if v < 0 {
        toDelete = append(toDelete, k)
    }
}
for _, k := range toDelete {
    delete(m, k)
}
```

### 陷阱 3：Map 不可比較

```go
m1 := map[string]int{"a": 1}
m2 := map[string]int{"a": 1}

// m1 == m2  // 編譯錯誤！map 不能用 == 比較

// 解法：使用 reflect.DeepEqual 或手動比較
import "reflect"
reflect.DeepEqual(m1, m2)  // true
```

### 陷阱 4：Map 是引用類型

```go
original := map[string]int{"a": 1}
copied := original  // 這不是複製！是同一個 map

copied["b"] = 2
fmt.Println(original)  // map[a:1 b:2] (也被修改了！)

// 真正的複製
copied := make(map[string]int, len(original))
for k, v := range original {
    copied[k] = v
}
```

### 陷阱 5：Key 的限制

```go
// Key 必須是可比較類型 (comparable)
// ✓ 可以：int, string, bool, pointer, struct (欄位都可比較), array
// ✗ 不行：slice, map, function

// 編譯錯誤
// m := map[[]int]string{}  // slice 不能當 key

// struct 作為 key：所有欄位必須可比較
type Point struct {
    X, Y int
}
m := map[Point]string{}
m[Point{1, 2}] = "A"  // OK

// 包含不可比較欄位的 struct 不能當 key
type Bad struct {
    Data []int  // slice 不可比較
}
// m := map[Bad]string{}  // 編譯錯誤
```

---

## 7. 用 Map 實作 Set

Go 沒有內建 Set 型別，但可以用 Map 輕鬆實作。

### 基本概念

```go
// Set 只關心「有沒有」，不關心「值是什麼」
// 所以用 map[T]struct{} 或 map[T]bool

// 方式 1：map[T]struct{} (推薦，不佔額外記憶體)
set := make(map[string]struct{})

// 方式 2：map[T]bool (較直觀)
set := make(map[string]bool)
```

### 為什麼用 struct{} 而不是 bool？

```go
// struct{} 是空結構，佔用 0 bytes
var s struct{}
fmt.Println(unsafe.Sizeof(s))  // 0

// bool 佔用 1 byte
var b bool
fmt.Println(unsafe.Sizeof(b))  // 1
```

> **結論**：當 Set 元素很多時，`map[T]struct{}` 可以省下可觀的記憶體。
{: .note }

### Set 完整實作

```go
// StringSet 型別定義
type StringSet map[string]struct{}

// 建立 Set
func NewStringSet(items ...string) StringSet {
    s := make(StringSet)
    for _, item := range items {
        s[item] = struct{}{}
    }
    return s
}

// 新增元素
func (s StringSet) Add(item string) {
    s[item] = struct{}{}
}

// 移除元素
func (s StringSet) Remove(item string) {
    delete(s, item)
}

// 檢查是否存在
func (s StringSet) Contains(item string) bool {
    _, ok := s[item]
    return ok
}

// 取得大小
func (s StringSet) Size() int {
    return len(s)
}

// 轉為 Slice
func (s StringSet) ToSlice() []string {
    result := make([]string, 0, len(s))
    for item := range s {
        result = append(result, item)
    }
    return result
}
```

### Set 常見操作

```go
// 聯集 (Union)
func (s StringSet) Union(other StringSet) StringSet {
    result := NewStringSet()
    for item := range s {
        result.Add(item)
    }
    for item := range other {
        result.Add(item)
    }
    return result
}

// 交集 (Intersection)
func (s StringSet) Intersection(other StringSet) StringSet {
    result := NewStringSet()
    for item := range s {
        if other.Contains(item) {
            result.Add(item)
        }
    }
    return result
}

// 差集 (Difference)
func (s StringSet) Difference(other StringSet) StringSet {
    result := NewStringSet()
    for item := range s {
        if !other.Contains(item) {
            result.Add(item)
        }
    }
    return result
}
```

### 使用範例

```go
// 建立並操作 Set
fruits := NewStringSet("apple", "banana", "orange")
fruits.Add("grape")
fruits.Remove("banana")

fmt.Println(fruits.Contains("apple"))   // true
fmt.Println(fruits.Contains("banana"))  // false
fmt.Println(fruits.Size())              // 3

// 集合運算
set1 := NewStringSet("a", "b", "c")
set2 := NewStringSet("b", "c", "d")

union := set1.Union(set2)           // {a, b, c, d}
intersection := set1.Intersection(set2)  // {b, c}
diff := set1.Difference(set2)       // {a}
```

### 快速用法 (不需要完整 Set 型別)

```go
// 檢查重複
func hasDuplicate(items []string) bool {
    seen := make(map[string]struct{})
    for _, item := range items {
        if _, ok := seen[item]; ok {
            return true  // 已存在
        }
        seen[item] = struct{}{}
    }
    return false
}

// 快速去重
func unique(items []string) []string {
    seen := make(map[string]struct{})
    result := []string{}
    for _, item := range items {
        if _, ok := seen[item]; !ok {
            seen[item] = struct{}{}
            result = append(result, item)
        }
    }
    return result
}

// 兩個 Slice 的交集
func intersection(a, b []string) []string {
    set := make(map[string]struct{})
    for _, item := range a {
        set[item] = struct{}{}
    }

    result := []string{}
    for _, item := range b {
        if _, ok := set[item]; ok {
            result = append(result, item)
        }
    }
    return result
}
```

---

## 8. 更多實用範例

### 統計字元出現次數

```go
func countChars(s string) map[rune]int {
    counts := make(map[rune]int)
    for _, ch := range s {
        counts[ch]++  // 利用零值特性，不需檢查
    }
    return counts
}

counts := countChars("hello")
// map[e:1 h:1 l:2 o:1]
```

### Slice 去重

```go
func unique(items []string) []string {
    seen := make(map[string]struct{})  // struct{} 不佔空間
    result := []string{}

    for _, item := range items {
        if _, ok := seen[item]; !ok {
            seen[item] = struct{}{}
            result = append(result, item)
        }
    }
    return result
}

unique([]string{"a", "b", "a", "c", "b"})
// ["a", "b", "c"]
```

> **技巧**：用 `map[T]struct{}` 而非 `map[T]bool` 實作 Set，因為 `struct{}` 不佔記憶體。
{: .note }

### 分組 (Group By)

```go
type User struct {
    Name    string
    Country string
}

func groupByCountry(users []User) map[string][]User {
    groups := make(map[string][]User)
    for _, u := range users {
        groups[u.Country] = append(groups[u.Country], u)
    }
    return groups
}
```

### 反轉 Map

```go
func invertMap(m map[string]int) map[int]string {
    inverted := make(map[int]string, len(m))
    for k, v := range m {
        inverted[v] = k  // 注意：若有重複 value，後者會覆蓋前者
    }
    return inverted
}
```

### 合併多個 Map

```go
func mergeMaps(maps ...map[string]int) map[string]int {
    result := make(map[string]int)
    for _, m := range maps {
        for k, v := range m {
            result[k] = v  // 後面的會覆蓋前面的
        }
    }
    return result
}
```

---

## 9. 效能優化建議

### 預分配容量

```go
// 差：頻繁擴容
m := make(map[string]int)
for i := 0; i < 10000; i++ {
    m[fmt.Sprint(i)] = i
}

// 好：預分配
m := make(map[string]int, 10000)
for i := 0; i < 10000; i++ {
    m[fmt.Sprint(i)] = i
}
```

### 避免在熱路徑建立 Map

```go
// 差：每次呼叫都建立 map
func process(data string) {
    lookup := map[string]int{"a": 1, "b": 2}  // 每次都重建
    // ...
}

// 好：提升為 package 變數或 struct 欄位
var lookup = map[string]int{"a": 1, "b": 2}

func process(data string) {
    // 使用 lookup
}
```

### 清空 Map 的方式

```go
// 方式 1：重新建立 (推薦，讓 GC 回收舊的)
m = make(map[string]int)

// 方式 2：逐一刪除 (保留已分配的空間)
for k := range m {
    delete(m, k)
}

// Go 1.21+：clear 內建函式
clear(m)  // 清空但保留空間
```

---

## 10. 常見面試題

### Q1：Map 的底層結構是什麼？
- Map 底層是 **hash table**，由多個 **bucket** 組成
- 每個 bucket 最多存 8 個 key-value pair
- 當 bucket 滿了會使用 **overflow bucket**
- 當元素過多會觸發 **rehash 擴容**

### Q2：為什麼 Map 遍歷順序是隨機的？
- Go 刻意加入隨機性，避免開發者依賴遍歷順序
- 如果順序固定，程式碼可能在某些情況下「恰好」正確，但其實是 bug

### Q3：Map 和 Slice 怎麼選？
| 需求 | 選擇 |
|:-----|:-----|
| 需要用 key 快速查找 | Map (O(1)) |
| 需要保持順序 | Slice |
| 需要頻繁遍歷 | Slice (較快) |
| 資料量小 (< 10) | Slice (可能更快) |

### Q4：如何實作一個 LRU Cache？
- 使用 `map` + `doubly linked list`
- Map 提供 O(1) 查找
- Linked list 維護存取順序

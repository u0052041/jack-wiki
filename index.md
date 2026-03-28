---
layout: default
title: 首頁
nav_order: 0
permalink: /
---

# Jack Ho — Backend Engineer
{: .fs-9 }

Golang & Python 後端工程師，專注於高流量系統架構設計與效能優化。
{: .fs-6 .fw-300 }

[Resume](resume.html){: .btn .btn-primary .fs-5 .mb-4 .mb-md-0 .mr-2 }
[Golang 筆記](golang/){: .btn .fs-5 .mb-4 .mb-md-0 .mr-2 }
[系統設計](system-design/){: .btn .fs-5 .mb-4 .mb-md-0 }

---

## Golang 筆記

從基礎語法到並發模型，適合有 Python 背景的開發者快速上手。

| 文章 | 說明 |
|------|------|
| [Struct & Pointer 基礎指南](golang/struct-and-pointer) | struct 宣告、pointer 語意、值傳遞 vs 指標傳遞 |
| [String & Rune 字串處理](golang/string-and-rune) | 字串底層、UTF-8、rune 迭代 |
| [Slice & Array 終極實戰指南](golang/array-and-slice) | slice 底層結構、append、copy、陷阱 |
| [Map 深度攻略](golang/map) | map 使用、nil map、並發安全 |
| [Methods & Interfaces](golang/interface-and-method) | 方法集、interface、duck typing |
| [閉包核心與實戰](golang/closure) | closure 原理、常見陷阱、實際應用 |
| [Defer & Switch 語法範例全集](golang/defer-and-switch) | defer 執行順序、switch 各種用法 |
| [Error 錯誤處理完全指南](golang/error) | error interface、wrapping、sentinel error |
| [Context 並發控制完全指南](golang/context) | context 傳遞、cancel、timeout、WithValue |
| [Goroutine & Channel 並發全攻略](golang/goroutine-and-channel) | goroutine、channel、select、sync |

---

## 系統設計

分散式系統、資料庫底層原理與實務架構筆記。

| 文章 | 說明 |
|------|------|
| [分散式系統理論](system-design/distributed-system) | CAP、BASE、一致性模型、共識演算法 |
| [資料庫底層原理](system-design/database-internal) | B-Tree、索引結構、MVCC、WAL |
| [Redis 底層原理](system-design/redis-internal) | 資料結構、持久化、過期機制、叢集 |
| [MySQL 線上不停機拆表實戰](system-design/mysql-table-split) | 雙寫流程、資料驗證、流量切換 |
| [資料庫事故排查手冊](system-design/database-incident-runbook) | 慢查詢、鎖等待、連線池耗盡的排查流程 |

---

## Infra / DevOps

基礎設施自動化、AWS 架構與 IaC 實務筆記。

| 文章 | 說明 |
|------|------|
| [Ansible 基礎速查](infra/ansible-notes) | inventory、playbook、roles、vault、rolling deployment |
| [AWS 加密速查](infra/aws-encryption-notes) | KMS、envelope encryption、at-rest、in-transit、Secrets Manager |
| [AWS VPC Networking](infra/aws-vpc-networking-notes) | subnet 設計、NAT GW、VPC Endpoint、ALB vs NLB、Session Manager |
| [Terraform + Jenkins 學習筆記](infra/jenkins/deploy-notes) | 共用 VPC networking 層、Remote State、ACM、ALB、user_data 安裝 Jenkins |

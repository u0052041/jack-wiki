---
layout: default
title: Resume
nav_order: 1
---

# Jack Ho

<img src="avatar.jpeg" alt="Jack Ho" width="150" style="border-radius: 50%;">

u0052041@gmail.com

7 年 Python 後端開發經驗，近期投入 Golang 學習，專注於高流量系統的架構設計與效能優化。曾於 DAU 50 萬的影音平台主導核心功能開發，具備資料庫與快取層調校、金流串接及第三方服務整合的實戰經驗，期望在微服務架構的團隊中持續深耕後端技術。

---

## 工作經歷

### 恒遠科技 — 資深後端工程師（2023/02 - 2026/01）

DAU 50 萬的影音平台，負責 Client 端與管理後台核心功能開發，參與需求技術可行性評估確保規格順利落地。

- 與 DBA 合作進行資料表拆分與高負載 API 查詢優化，消除 slow query 並將 RDS 降低兩個規格
- 將 ElastiCache 大 key 拆分為數個分片，調整部分數據的底層資料結構，使 ElastiCache 降低一個規格
- 在高頻低異動資料上引入 in-process cache 搭配寫入主動清除策略，有效減少 Redis 查詢次數
- 獨立串接第三方直播服務，負責從技術評估、API 整合到上線維護，包含直播間充值與抖內小遊戲等對帳
- 設計金流冪等機制，確保 callback 與主動查單情境下不發生重複扣款或重複入帳，保障交易資料一致性
- 獨立串接即時通訊第三方服務，除了 client 端的用戶消息發送，也包含重構後台客服系統，實作客服分配邏輯
- 重構影音處理流程，將 FFmpeg 切片加密後直傳 AWS S3，取代原有第三方雲端方案，降低上傳錯誤率並減少對外部服務的依賴

### UrMart — 後端工程師（2021/04 - 2023/02）

負責電商新版官網從開發到上線後的持續迭代，整合金流、物流、SMS 通知等第三方服務。

- 優化商品列表、購物車、結帳等核心 API，Response Time 穩定維持於 200-300ms
- 串接 PxPay、TapPay 等金流服務，重構支付流程統一不同支付方式的介接邏輯
- 負責雙 11 等活動檔期的壓力測試，預估尖峰流量所需 server 容量，確保 2000 人同時在線時系統穩定運行
- 利用 Metabase 撰寫複雜 SQL 進行數據分析，提供關鍵營運指標供各部門決策參考
- 參與系統的 CI/CD 建置，負責 Elastic Beanstalk 優化縮短上版時間

### 王族遊戲科技 — 後端工程師（2016/10 - 2021/03）

以 IT 職務入職後自學轉型後端開發，從 0 到 1 開發公司內部管理系統，撰寫 integration test 確保核心功能正確性並修復 N+1 query 問題優化效能，同時以 Python + Selenium 實作自動化流程取代人工重複操作。

---

## 技能

**Backend:** Python, Golang, Celery, Redis, RabbitMQ, PostgreSQL/MySQL, MongoDB, Nginx, FFmpeg

**DevOps:** GitHub Actions, Docker, AWS, GCP

**Others:** Git, JavaScript/jQuery, Selenium, Scrum

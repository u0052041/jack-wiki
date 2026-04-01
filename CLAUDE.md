# jack-wiki

Personal knowledge wiki. Jekyll + just-the-docs, hosted on GitHub Pages.
Live: https://u0052041.github.io/jack-wiki

## Directory Purpose

- `golang/` — Golang 語言深度筆記（給有 Python 背景的開發者）
- `system-design/` — 系統設計面試題 + 資深後端工程師應掌握的知識
- `infra/` — DevOps 轉職學習筆記 + 真實 AWS Terraform 架構

## Infra: Notes ↔ Config 對應原則

`infra/` 下的 `.tf` / `.yaml` 是實際部署的 AWS 資源，每份設定檔都應有對應的 `.md` 筆記說明決策與 gotcha，反之亦然。

**Terraform 部署順序：**
1. `infra/networking/` — VPC / ACM（其他模組的基礎）
2. `infra/jenkins/` — Jenkins CI
3. `infra/k8s/` — EKS + ALB Controller

> **Warning:** `terraform.tfstate` 追蹤真實 AWS 資源，勿隨意刪除或覆寫。

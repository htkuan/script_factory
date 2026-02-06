# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Does

這是一個 Shell Script 工廠，用來撰寫可跨裝置運行的 shell script。每個腳本只依賴常見的 CLI 工具（如 `gh`、`curl`、`jq`、`sed`、`date`），不需要額外的 runtime 或套件管理器。換裝置時只要確認這些 CLI 工具已安裝即可。

## Architecture

每個服務（對應一個第三方平台）是一個獨立目錄，包含：

- **`<service>.sh`** — 主要腳本，負責呼叫 API 抓取資料、轉換並輸出 JSON / Markdown
- **`config.json`** — 執行時的設定檔（含 token，已 gitignore）
- **`config.example.json`** — 設定範例，用 placeholder 取代真實值

## Conventions

### 新增腳本時遵循的 pattern

1. 建立新目錄 `<service>/`
2. 腳本開頭使用 `set -euo pipefail`（嚴格模式）
3. 用 `command -v` 檢查 CLI 依賴是否存在，缺少時報錯退出
4. 設定從 `config.json` 讀取（透過 `jq -r`），邏輯與設定分離
5. API 呼叫需帶 rate-limit 重試邏輯（參考 slack/asana 的實作）
6. 輸出格式：先產 JSON，再轉 Markdown
7.  提供 `config.example.json`，真實的 `config.json` 由 `.gitignore` 排除

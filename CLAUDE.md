# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Does

這是一個 Script 工廠，用來撰寫可跨裝置運行的腳本。支援兩種類型：

- **Shell Script** — 只依賴常見的 CLI 工具（如 `gh`、`curl`、`jq`、`sed`、`date`），不需要額外的 runtime 或套件管理器。
- **Python Script** — 透過 `uv` 管理 Python 環境與套件，每個腳本目錄各自維護獨立的 `.venv`。

換裝置時只要確認 CLI 工具與 `uv` 已安裝即可。

## Architecture

每個服務（對應一個第三方平台或功能）是一個獨立目錄，依腳本類型包含不同檔案：

### Shell Script 目錄結構

- **`<service>.sh`** — 主要腳本，負責呼叫 API 抓取資料、轉換並輸出 JSON / Markdown
- **`config.json`** — 執行時的設定檔（含 token，已 gitignore）
- **`config.example.json`** — 設定範例，用 placeholder 取代真實值

### Python Script 目錄結構

- **`<service>.py`** — 主要 Python 腳本
- **`pyproject.toml`** — 套件依賴定義，由 `uv` 管理
- **`.venv/`** — 該腳本專屬的虛擬環境（已 gitignore）
- **`config.json`** — 執行時的設定檔（含 token，已 gitignore）
- **`config.example.json`** — 設定範例，用 placeholder 取代真實值

## Conventions

### 新增 Shell Script 時遵循的 pattern

1. 建立新目錄 `<service>/`
2. 腳本開頭使用 `set -euo pipefail`（嚴格模式）
3. 用 `command -v` 檢查 CLI 依賴是否存在，缺少時報錯退出
4. 設定從 `config.json` 讀取（透過 `jq -r`），邏輯與設定分離
5. API 呼叫需帶 rate-limit 重試邏輯（參考 slack/asana 的實作）
6. 輸出格式：先產 JSON，再轉 Markdown
7. 提供 `config.example.json`，真實的 `config.json` 由 `.gitignore` 排除

### 新增 Python Script 時遵循的 pattern

1. 建立新目錄 `<service>/`
2. 在目錄內執行 `uv init` 初始化專案，產生 `pyproject.toml`
3. 用 `uv add <package>` 加入依賴，會自動建立 `.venv/`
4. 腳本透過 `uv run <service>.py` 執行，自動使用該目錄的 `.venv`
5. 設定從 `config.json` 讀取，邏輯與設定分離
6. 提供 `config.example.json`，真實的 `config.json` 由 `.gitignore` 排除
7. `.venv/` 目錄由 `.gitignore` 排除，不進版控

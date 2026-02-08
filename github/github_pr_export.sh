#!/usr/bin/env bash

# ============================================
# github_pr_export.sh
# 從 GitHub 匯出指定組織內多位作者的已合併 PR，
# 依 repo 分組整理後輸出 JSON 與 Markdown 報告。
# 主要流程：
# 1) 從 config.json 讀取 org 與 authors 列表
# 2) 對每位 author 呼叫 gh search prs 取得已合併 PR
# 3) 並行抓取每個 PR 的詳細資訊（含 commits、reviews、comments）
# 4) 使用 jq 依 repo 分組、按 mergedAt 排序
# 5) 輸出 JSON 與 per-repo Markdown 檔案
# ============================================

# 嚴格模式 — -e: 指令失敗立即終止; -u: 使用未定義變數報錯; -o pipefail: 管線中任一指令失敗則整條管線失敗
set -euo pipefail

# 腳本所在目錄的絕對路徑
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Skill 根目錄（腳本位於 scripts/ 子目錄內，上一層即為 skill root）
readonly SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# Skill 設定檔路徑（包含 org 與 authors 清單）
readonly CONFIG_FILE="${SKILL_DIR}/config.json"
# 專案根目錄（透過 git 定位，用於決定輸出路徑）
readonly PROJECT_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)"

# --- 依賴檢查 ---
for cmd in gh jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: '$cmd' is required but not installed." >&2
        exit 1
    fi
done

# --- 參數驗證 ---
if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <start_date> <end_date>"
    echo "Example: $0 2026-01-01 2026-01-31"
    exit 1
fi

readonly START_DATE="$1"
readonly END_DATE="$2"

# --- 日期格式驗證 (YYYY-MM-DD) ---
validate_date() {
    local d="$1" label="$2"
    if ! [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo "ERROR: $label '$d' is not in YYYY-MM-DD format." >&2
        exit 1
    fi
    if ! date -j -f "%Y-%m-%d" "$d" "+%Y-%m-%d" &>/dev/null; then
        echo "ERROR: $label '$d' is not a valid date." >&2
        exit 1
    fi
}

validate_date "$START_DATE" "start_date"
validate_date "$END_DATE" "end_date"

if [[ "$START_DATE" > "$END_DATE" ]]; then
    echo "ERROR: start_date ($START_DATE) must be <= end_date ($END_DATE)." >&2
    exit 1
fi

# --- config.json 驗證 ---
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: config.json not found at $CONFIG_FILE" >&2
    echo "Please create one based on config.example.json" >&2
    exit 1
fi

readonly ORG=$(jq -r '.org // empty' "$CONFIG_FILE")
if [[ -z "$ORG" ]]; then
    echo "ERROR: 'org' is missing or empty in config.json" >&2
    exit 1
fi

readonly AUTHORS_COUNT=$(jq '.authors | length' "$CONFIG_FILE")
if [[ "$AUTHORS_COUNT" -eq 0 ]]; then
    echo "ERROR: 'authors' array is empty in config.json" >&2
    exit 1
fi

# 從 config.json 讀取 authors 陣列到 bash 陣列
AUTHORS=()
while IFS= read -r a; do
    AUTHORS+=("$a")
done < <(jq -r '.authors[]' "$CONFIG_FILE")

# 顯示執行摘要資訊
echo "======================================"
echo "Org:        $ORG"
echo "Authors:    ${AUTHORS[*]}"
echo "Date Range: $START_DATE to $END_DATE"
echo "Config:     $CONFIG_FILE"
echo "Output:     $PROJECT_ROOT/github_data/"
echo "======================================"

# --- 帶重試邏輯的 PR 抓取函式 ---
fetch_pr_with_retry() {
    local pr="$1" repo="$2" max_retries=3 attempt=0
    while [[ $attempt -lt $max_retries ]]; do
        if gh pr view "$pr" --repo "$repo" \
            --json number,title,body,commits,comments,reviews,createdAt,mergedAt,state,url 2>/dev/null; then
            return 0
        fi
        attempt=$((attempt + 1))
        echo "    Retry $attempt/$max_retries after ${attempt}s..." >&2
        sleep "$attempt"
    done
    echo "    ERROR: Failed to fetch $repo #$pr after $max_retries retries" >&2
    return 1
}

# 匯出函數供 xargs -P 產生的子 shell 使用（Bash-only 特性）
export -f fetch_pr_with_retry

# --- 腳本層級暫存目錄與 trap 清理 ---
readonly SCRIPT_TMPDIR=$(mktemp -d)
trap 'rm -rf "$SCRIPT_TMPDIR"' EXIT

# --- 單一 author 的處理函式 ---
process_author() {
    local author="$1"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Processing: $author"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # 建立輸出目錄與暫存檔路徑
    local output_dir="${PROJECT_ROOT}/github_data/${START_DATE}_${END_DATE}/${author}"
    local output_file="${output_dir}/prs_by_repo.json"
    local temp_file="${SCRIPT_TMPDIR}/prs_raw_${author}.json"

    mkdir -p "$output_dir"

    # Step 1: 取得所有已 merge 的 PR 列表
    echo "[Step 1] Fetching merged PR list for $author..."

    local pr_list
    pr_list=$(gh search prs \
        --owner "$ORG" \
        --author "$author" \
        --created "${START_DATE}..${END_DATE}" \
        --merged \
        --json repository,number \
        --jq '.[] | "\(.repository.nameWithOwner) \(.number)"')

    local pr_count
    if [[ -z "$pr_list" ]]; then
        pr_count=0
    else
        pr_count=$(echo "$pr_list" | wc -l | tr -d ' ')
    fi
    echo "  Found $pr_count merged PRs"

    if [[ "$pr_count" -eq 0 ]]; then
        echo "  No PRs found for $author. Skipping."
        return 0
    fi

    # Step 2: 抓取每個 PR 的詳細內容（並行）
    echo "[Step 2] Fetching PR details ($pr_count PRs, 5 parallel workers)..."

    > "$temp_file"
    local parallel_jobs=5
    local temp_dir="${SCRIPT_TMPDIR}/prs_parallel_${author}"
    mkdir -p "$temp_dir"

    echo "$pr_list" | xargs -P "$parallel_jobs" -L 1 bash -c '
        repo="$1"; pr="$2"
        fetch_pr_with_retry "$pr" "$repo" > "'"$temp_dir"'/${pr}_${repo//\//_}.json"
    ' _

    cat "$temp_dir"/*.json > "$temp_file" 2>/dev/null || true
    rm -rf "$temp_dir"

    # Step 3: 合併成 JSON 陣列
    echo "[Step 3] Combining into JSON array..."
    local prs_array_file="${SCRIPT_TMPDIR}/prs_array_${author}.json"
    jq -s '.' "$temp_file" > "$prs_array_file"

    # Step 4: 以 repo 分類並按 mergedAt 排序
    echo "[Step 4] Grouping by repo and sorting by merge time..."
    jq '
      group_by(.url | split("/")[4]) |
      map({
        (.[0].url | split("/")[4]): (sort_by(.mergedAt) | reverse)
      }) |
      add
    ' "$prs_array_file" > "$output_file"

    # 清理暫存檔
    rm -f "$temp_file" "$prs_array_file"

    # 顯示每個 repo 的 PR 數量統計
    echo "  Stats:"
    jq 'to_entries | map("    \(.key): \(.value | length) PRs") | .[]' -r "$output_file"

    # Step 5: 轉換成 Markdown 檔案
    echo "[Step 5] Converting to Markdown files..."

    while IFS= read -r repo; do
        local md_file="${output_dir}/${repo}.md"
        jq -r --arg repo "$repo" '
          def pr_md:
            "## [#" + (.number|tostring) + "](" + .url + ") " + (.title // "") + "\n\n" +
            "- Merged At: " + (.mergedAt // "N/A") + "\n" +
            "- Created At: " + (.createdAt // "N/A") + "\n" +
            "- Commits: " + ((.commits // []) | length | tostring) + "\n" +
            "- Reviews: " + ((.reviews // []) | length | tostring) + "\n" +
            "- Comments: " + ((.comments // []) | length | tostring) + "\n\n" +
            "Description:\n" + (.body // "") + "\n";
          "# " + $repo + "\n\n" + (.[ $repo ] | map(pr_md) | join("\n---\n\n"))
        ' "$output_file" > "$md_file"
        echo "  - $md_file"
    done < <(jq -r 'keys[]' "$output_file")
}

# --- 主流程：遍歷所有 authors ---
for author in "${AUTHORS[@]}"; do
    process_author "$author"
done

echo ""
echo "======================================"
echo "All done! Output directory: ${PROJECT_ROOT}/github_data/${START_DATE}_${END_DATE}/"
echo "======================================"

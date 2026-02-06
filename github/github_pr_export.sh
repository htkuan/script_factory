#!/bin/bash

# ============================================
# github_pr_export.sh
# Fetch all merged PRs for authors in an org
# Reads org & authors from ./config.json
# ============================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.json"

# --- 依賴檢查 ---
for cmd in gh jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: '$cmd' is required but not installed." >&2
        exit 1
    fi
done

# --- 參數驗證 ---
if [ $# -lt 2 ]; then
    echo "Usage: $0 <start_date> <end_date>"
    echo "Example: $0 2026-01-01 2026-01-31"
    exit 1
fi

START_DATE="$1"
END_DATE="$2"

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
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: config.json not found at $CONFIG_FILE" >&2
    echo "Please create one based on config.example.json" >&2
    exit 1
fi

ORG=$(jq -r '.org // empty' "$CONFIG_FILE")
if [ -z "$ORG" ]; then
    echo "ERROR: 'org' is missing or empty in config.json" >&2
    exit 1
fi

AUTHORS_COUNT=$(jq '.authors | length' "$CONFIG_FILE")
if [ "$AUTHORS_COUNT" -eq 0 ]; then
    echo "ERROR: 'authors' array is empty in config.json" >&2
    exit 1
fi

AUTHORS=()
while IFS= read -r a; do
    AUTHORS+=("$a")
done < <(jq -r '.authors[]' "$CONFIG_FILE")

echo "======================================"
echo "Org:        $ORG"
echo "Authors:    ${AUTHORS[*]}"
echo "Date Range: $START_DATE to $END_DATE"
echo "======================================"

# --- 帶重試邏輯的 PR 抓取函式 ---
fetch_pr_with_retry() {
    local pr="$1" repo="$2" max_retries=3 attempt=0
    while [ $attempt -lt $max_retries ]; do
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

export -f fetch_pr_with_retry

# --- 單一 author 的處理函式 ---
process_author() {
    local author="$1"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Processing: $author"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local output_dir="${SCRIPT_DIR}/../github_data/${START_DATE}_${END_DATE}/${author}"
    local output_file="${output_dir}/prs_by_repo.json"
    local temp_file="/tmp/prs_raw_${author}_$$.json"

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
    if [ -z "$pr_list" ]; then
        pr_count=0
    else
        pr_count=$(echo "$pr_list" | wc -l | tr -d ' ')
    fi
    echo "  Found $pr_count merged PRs"

    if [ "$pr_count" -eq 0 ]; then
        echo "  No PRs found for $author. Skipping."
        return 0
    fi

    # Step 2: 抓取每個 PR 的詳細內容（並行）
    echo "[Step 2] Fetching PR details ($pr_count PRs, 5 parallel workers)..."

    > "$temp_file"
    local parallel_jobs=5
    local temp_dir="/tmp/prs_parallel_${author}_$$"
    mkdir -p "$temp_dir"

    echo "$pr_list" | xargs -P "$parallel_jobs" -L 1 bash -c '
        repo="$1"; pr="$2"
        fetch_pr_with_retry "$pr" "$repo" > "'"$temp_dir"'/${pr}_${repo//\//_}.json"
    ' _

    cat "$temp_dir"/*.json > "$temp_file" 2>/dev/null || true
    rm -rf "$temp_dir"

    # Step 3: 合併成 JSON 陣列
    echo "[Step 3] Combining into JSON array..."
    jq -s '.' "$temp_file" > "/tmp/prs_array_${author}_$$.json"

    # Step 4: 以 repo 分類並按 mergedAt 排序
    echo "[Step 4] Grouping by repo and sorting by merge time..."
    jq '
      group_by(.url | split("/")[4]) |
      map({
        (.[0].url | split("/")[4]): (sort_by(.mergedAt) | reverse)
      }) |
      add
    ' "/tmp/prs_array_${author}_$$.json" > "$output_file"

    rm -f "$temp_file" "/tmp/prs_array_${author}_$$.json"

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
echo "All done! Output directory: github_data/${START_DATE}_${END_DATE}/"
echo "======================================"

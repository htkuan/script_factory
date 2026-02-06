#!/bin/bash

# ============================================
# fetch_author_prs.sh
# Fetch all merged PRs for an author in an org
# ============================================

set -e

# --- 參數驗證 ---
if [ $# -lt 4 ]; then
    echo "Usage: $0 <org> <author> <start_date> <end_date>"
    echo "Example: $0 chatbotgang gearoidfan 2026-01-01 2026-01-31"
    exit 1
fi

ORG="$1"
AUTHOR="$2"
START_DATE="$3"
END_DATE="$4"
OUTPUT_FILE="${AUTHOR}_${START_DATE}_${END_DATE}_prs_by_repo.json"
TEMP_FILE="/tmp/prs_raw_$$.json"

echo "======================================"
echo "Org:        $ORG"
echo "Author:     $AUTHOR"
echo "Date Range: $START_DATE to $END_DATE"
echo "Output:     $OUTPUT_FILE"
echo "======================================"

# --- Step 1: 取得所有已 merge 的 PR 列表 ---
echo ""
echo "[Step 1] Fetching merged PR list..."

PR_LIST=$(gh search prs \
    --owner "$ORG" \
    --author "$AUTHOR" \
    --created "${START_DATE}..${END_DATE}" \
    --merged \
    --json repository,number \
    --jq '.[] | "\(.repository.nameWithOwner) \(.number)"')

if [ -z "$PR_LIST" ]; then
    PR_COUNT=0
else
    PR_COUNT=$(echo "$PR_LIST" | wc -l | tr -d ' ')
fi
echo "Found $PR_COUNT merged PRs"

if [ "$PR_COUNT" -eq 0 ]; then
    echo "No PRs found. Exiting."
    exit 0
fi

# --- Step 2: 抓取每個 PR 的詳細內容（並行） ---
echo ""
echo "[Step 2] Fetching PR details..."

> "$TEMP_FILE"  # 清空暫存檔

# 帶重試邏輯的 PR 抓取函式
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

PARALLEL_JOBS=5
TEMP_DIR="/tmp/prs_parallel_$$"
mkdir -p "$TEMP_DIR"

echo "  Fetching $PR_COUNT PRs with $PARALLEL_JOBS parallel workers..."

echo "$PR_LIST" | xargs -P "$PARALLEL_JOBS" -L 1 bash -c '
    repo="$1"; pr="$2"
    fetch_pr_with_retry "$pr" "$repo" > "'"$TEMP_DIR"'/${pr}_${repo//\//_}.json"
' _

# 合併所有並行結果
cat "$TEMP_DIR"/*.json > "$TEMP_FILE" 2>/dev/null || true
rm -rf "$TEMP_DIR"

echo "  Completed fetching $PR_COUNT PRs."

# --- Step 3: 合併成 JSON 陣列 ---
echo ""
echo "[Step 3] Combining into JSON array..."

jq -s '.' "$TEMP_FILE" > "/tmp/prs_array_$$.json"

# --- Step 4: 以 repo 分類並按 mergedAt 排序 ---
echo ""
echo "[Step 4] Grouping by repo and sorting by merge time..."

jq '
  group_by(.url | split("/")[4]) |
  map({
    (.[0].url | split("/")[4]): (sort_by(.mergedAt) | reverse)
  }) |
  add
' "/tmp/prs_array_$$.json" > "$OUTPUT_FILE"

# --- 清理暫存檔 ---
rm -f "$TEMP_FILE" "/tmp/prs_array_$$.json"

# --- 完成 ---
echo ""
echo "======================================"
echo "Done! Output saved to: $OUTPUT_FILE"
echo ""
echo "Stats:"
jq 'to_entries | map({repo: .key, count: (.value | length)})' "$OUTPUT_FILE"
echo "======================================"

# --- Step 5: 轉換成 Markdown 檔案 ---
echo ""
echo "[Step 5] Converting to Markdown files..."

GENERATED_FILES=()

while IFS= read -r repo; do
    md_file="${AUTHOR}_${START_DATE}_${END_DATE}_${repo}.md"
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
    ' "$OUTPUT_FILE" > "$md_file"
    GENERATED_FILES+=("$md_file")
done < <(jq -r 'keys[]' "$OUTPUT_FILE")

echo ""
echo "Generated Markdown files:"
for md_file in "${GENERATED_FILES[@]}"; do
    echo "  - $md_file"
done

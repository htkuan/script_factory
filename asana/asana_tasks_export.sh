#!/usr/bin/env bash
# 本腳本用來從 Asana 匯出指定 Sprint（或指定 Sprint GID）的任務，
# 依負責人 (assignee) 分組整理後輸出 JSON，並可選擇產生 Markdown 報告。
# 主要流程：
# 1) 讀取 asana.json 取得 workspace_id / project_id / token
# 2) 呼叫 Asana API 搜尋 Sprint 內任務（含分頁）
# 3) 為每個任務補上子任務與（可選）留言
# 4) 使用 jq 依負責人分組、統計完成/未完成數
# 5) 輸出 JSON 與（可選）Markdown
set -euo pipefail

# 依賴檢查
for dep in jq curl; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    echo "Missing dependency: $dep" >&2
    exit 1
  fi
done

# 統一的 API 呼叫函數（帶有逾時、重試與錯誤處理）
api_call() {
  local url="$1"
  local attempt=1
  local max_attempts=3
  local backoff=1

  while (( attempt <= max_attempts )); do
    local body_file header_file http_code retry_after
    body_file=$(mktemp)
    header_file=$(mktemp)
    http_code=""

    if curl -s -S -X GET "$url" \
      -H "Authorization: Bearer ${token}" \
      --connect-timeout 10 \
      --max-time 30 \
      -D "$header_file" \
      -o "$body_file"; then
      http_code=$(awk 'NR==1{print $2}' "$header_file")
    fi

    if [[ -n "$http_code" && "$http_code" =~ ^2 ]]; then
      cat "$body_file"
      rm -f "$body_file" "$header_file"
      return 0
    fi

    if [[ "$http_code" == "429" ]]; then
      retry_after=$(awk -F': ' 'tolower($1)=="retry-after"{print $2; exit}' "$header_file" | tr -d '\r')
      if [[ -n "$retry_after" && "$retry_after" =~ ^[0-9]+$ ]]; then
        sleep "$retry_after"
      else
        sleep "$backoff"
      fi
    elif [[ -z "$http_code" || "$http_code" =~ ^5 ]]; then
      sleep "$backoff"
    fi

    rm -f "$body_file" "$header_file"

    if [[ -z "$http_code" || "$http_code" == "429" || "$http_code" =~ ^5 ]]; then
      attempt=$((attempt + 1))
      backoff=$((backoff * 2))
      continue
    fi

    break
  done

  echo ""
  return 1
}

# 顯示使用方式與參數說明的函數
usage() {
  echo "Usage: $(basename "$0") <asana.json> [SPRINT_GID]" >&2
  echo "" >&2
  echo "Arguments:" >&2
  echo "  asana.json   Asana config file path (required)" >&2
  echo "  SPRINT_GID   Sprint GID (optional; interactive selection if omitted)" >&2
  exit 1
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
fi

# 解析命令列參數
readonly asana_json="$1"
sprint_gid="${2:-}"

# 功能開關：是否產生 Markdown 報告、是否抓取留言
readonly generate_markdown=true
readonly with_comments=true

if [[ ! -f "$asana_json" ]]; then
  echo "Missing $asana_json" >&2
  exit 1
fi

# 從 asana.json 讀取必要的 Asana 設定
readonly workspace_id=$(jq -r '.workspace_id // empty' "$asana_json")
readonly project_id=$(jq -r '.project_id // empty' "$asana_json")
readonly token=$(jq -r '.token // empty' "$asana_json")
readonly sprint_custom_field_gid=$(jq -r '.sprint_custom_field_gid // empty' "$asana_json")

# 檢查必要欄位是否齊全，缺少任一則報錯退出
missing_fields=()
if [[ -z "$workspace_id" ]]; then
  missing_fields+=("workspace_id")
fi
if [[ -z "$project_id" ]]; then
  missing_fields+=("project_id")
fi
if [[ -z "$token" ]]; then
  missing_fields+=("token")
fi
if [[ -z "$sprint_custom_field_gid" ]]; then
  missing_fields+=("sprint_custom_field_gid")
fi

if [[ "${#missing_fields[@]}" -gt 0 ]]; then
  echo "asana.json missing required fields: ${missing_fields[*]}" >&2
  exit 1
fi

# 匯出 token 到環境變數，因為 xargs -P 產生的子 shell 需要存取 token
export token

# 若未提供 Sprint GID，則互動式列出可選 Sprint
if [[ -z "$sprint_gid" ]]; then
  custom_field_url="https://app.asana.com/api/1.0/custom_fields/${sprint_custom_field_gid}"
  echo "Fetching available sprints from Asana..." >&2
  custom_field_response=$(api_call "$custom_field_url")

  if [[ -z "$custom_field_response" ]]; then
    echo "Asana API call failed: $custom_field_url" >&2
    exit 1
  fi

  if echo "$custom_field_response" | jq -e '.errors' > /dev/null 2>&1; then
    echo "Asana API error:" >&2
    echo "$custom_field_response" | jq -r '.errors[].message' >&2
    exit 1
  fi

  sprint_options=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && sprint_options+=("$line")
  done < <(echo "$custom_field_response" | jq -r '.data.enum_options[]? | "\(.gid)\t\(.name)"')

  if [[ "${#sprint_options[@]}" -eq 0 ]]; then
    echo "No sprint options found in custom field ${sprint_custom_field_gid}" >&2
    exit 1
  fi

  echo "Available sprints:" >&2
  for i in "${!sprint_options[@]}"; do
    gid="${sprint_options[$i]%%$'\t'*}"
    name="${sprint_options[$i]#*$'\t'}"
    echo "$((i + 1))) ${name} (gid: ${gid})" >&2
  done

  while true; do
    read -r -p "Select sprint [1-${#sprint_options[@]}]: " selection
    if [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= ${#sprint_options[@]} )); then
      break
    fi
    echo "Invalid selection. Please enter a number between 1 and ${#sprint_options[@]}." >&2
  done

  selected="${sprint_options[$((selection - 1))]}"
  sprint_gid="${selected%%$'\t'*}"
  sprint_name="${selected#*$'\t'}"
else
  if [[ ! "$sprint_gid" =~ ^[0-9]+$ ]]; then
    echo "Invalid SPRINT_GID: ${sprint_gid}" >&2
    exit 1
  fi
  custom_field_url="https://app.asana.com/api/1.0/custom_fields/${sprint_custom_field_gid}"
  custom_field_response=$(api_call "$custom_field_url")
  if [[ -n "$custom_field_response" ]]; then
    sprint_name=$(echo "$custom_field_response" | jq -r --arg gid "$sprint_gid" '.data.enum_options[]? | select(.gid == $gid) | .name // empty')
  fi
  if [[ -z "${sprint_name:-}" ]]; then
    sprint_name="Sprint ${sprint_gid}"
  fi
fi

# 建立以 Sprint 名稱命名的輸出目錄（/ 替換為 - 避免路徑問題）
readonly output_dir="asana_data/$(echo "$sprint_name" | sed 's|/|-|g')"
mkdir -p "$output_dir"

# 建立暫存目錄（用於大型 JSON 與並行處理）
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

# 建立 Asana API 查詢 URL 與欄位清單
# API：GET /workspaces/{workspace_gid}/tasks/search
# opt_fields 指定要回傳的欄位，避免多次查詢
readonly base_url="https://app.asana.com/api/1.0/workspaces/${workspace_id}/tasks/search"
readonly opt_fields="gid,name,completed,notes,due_on,start_on,created_at,modified_at,assignee.gid,assignee.name,assignee.email,custom_fields.name,custom_fields.display_value,custom_fields.enum_value.name,tags.name,permalink_url"

echo "Fetching tasks for sprint: ${sprint_name}..." >&2

# 分頁拉取所有任務
# Asana 搜尋 API 一次最多回傳 limit 筆，需用 next_page.offset 續頁
all_tasks_file="${tmp_dir}/all_tasks.json"
echo "[]" > "$all_tasks_file"
offset=""

while true; do
  # 依 Sprint 自訂欄位過濾指定 Sprint 的任務
  url="${base_url}?projects.all=${project_id}&custom_fields.${sprint_custom_field_gid}.value=${sprint_gid}&opt_fields=${opt_fields}&limit=100"

  if [[ -n "$offset" ]]; then
    url="${url}&offset=${offset}"
  fi

  # API 呼叫：取得一頁任務清單
  response=$(api_call "$url")

  if [[ -z "$response" ]]; then
    echo "Asana API call failed: $url" >&2
    exit 1
  fi

  # 檢查 API 是否回傳 errors
  if echo "$response" | jq -e '.errors' > /dev/null 2>&1; then
    echo "Asana API error:" >&2
    echo "$response" | jq -r '.errors[].message' >&2
    exit 1
  fi

  # 將本頁任務合併到總清單
  page_tasks=$(echo "$response" | jq '.data')
  jq -s 'add' "$all_tasks_file" - <<< "$page_tasks" > "${tmp_dir}/all_tasks_merged.json"
  mv "${tmp_dir}/all_tasks_merged.json" "$all_tasks_file"

  # 取出 next_page.offset，若沒有表示已到最後一頁
  offset=$(echo "$response" | jq -r '.next_page.offset // empty')
  if [[ -z "$offset" ]]; then
    break
  fi
done

total_tasks=$(jq 'length' "$all_tasks_file")
echo "Found ${total_tasks} tasks. Fetching subtasks..." >&2

# 取得單一任務的子任務清單
# API：GET /tasks/{task_gid}/subtasks?opt_fields=...
fetch_subtasks() {
  local task_gid="$1"
  local subtasks_url="https://app.asana.com/api/1.0/tasks/${task_gid}/subtasks?opt_fields=gid,name,completed,notes,due_on,assignee.name,assignee.gid"

  local subtasks_response
  # API 呼叫：子任務列表
  subtasks_response=$(api_call "$subtasks_url")

  if [[ -z "$subtasks_response" ]]; then
    echo "[]"
    return
  fi

  if echo "$subtasks_response" | jq -e '.errors' > /dev/null 2>&1; then
    echo "[]"
    return
  fi

  echo "$subtasks_response" | jq '.data'
}

# 取得單一任務的留言（stories 中的 comment 類型）
# API：GET /tasks/{task_gid}/stories?opt_fields=...
fetch_comments() {
  local task_gid="$1"
  local stories_url="https://app.asana.com/api/1.0/tasks/${task_gid}/stories?opt_fields=gid,created_at,created_by.name,text,type,resource_subtype"

  local stories_response
  # API 呼叫：任務動態/留言列表
  stories_response=$(api_call "$stories_url")

  if [[ -z "$stories_response" ]]; then
    echo "[]"
    return
  fi

  if echo "$stories_response" | jq -e '.errors' > /dev/null 2>&1; then
    echo "[]"
    return
  fi

  # 僅保留 type == "comment" 的留言，排除系統事件
  echo "$stories_response" | jq '[.data[] | select(.type == "comment") | {
    gid: .gid,
    created_at: .created_at,
    author: (.created_by.name // "System"),
    text: .text
  }]'
}

# 並行補齊每個任務的子任務與（可選）留言
fetch_task_details() {
  local task_gid="$1"
  local tmp_dir="$2"
  local with_comments="$3"
  local all_tasks_file="${tmp_dir}/all_tasks.json"
  local task_file="${tmp_dir}/task_${task_gid}.json"

  local task subtasks comments task_with_subtasks
  task=$(jq -c --arg gid "$task_gid" '.[] | select(.gid == $gid)' "$all_tasks_file" | head -n 1 || true)
  if [[ -z "$task" ]]; then
    jq -n --arg gid "$task_gid" '{gid: $gid, subtasks: [], comments: []}' > "$task_file"
    return 0
  fi

  subtasks=$(fetch_subtasks "$task_gid")
  task_with_subtasks=$(echo "$task" | jq --argjson subtasks "$subtasks" '. + {subtasks: $subtasks}')

  if [[ "$with_comments" == "true" ]]; then
    comments=$(fetch_comments "$task_gid")
    task_with_subtasks=$(echo "$task_with_subtasks" | jq --argjson comments "$comments" '. + {comments: $comments}')
  else
    task_with_subtasks=$(echo "$task_with_subtasks" | jq '. + {comments: []}')
  fi

  echo "$task_with_subtasks" > "$task_file"
}

# 匯出函數供 xargs -P 產生的子 shell 使用（Bash-only 特性）
export -f api_call
export -f fetch_subtasks
export -f fetch_comments
export -f fetch_task_details

tasks_with_subtasks="[]"

# 以 10 個並行 worker 抓取每個任務的子任務與留言
if [[ "$total_tasks" -gt 0 ]]; then
  task_gids=$(jq -r '.[].gid' "$all_tasks_file")
  echo "$task_gids" | xargs -P 10 -I {} bash -c 'fetch_task_details "$@"' _ {} "$tmp_dir" "$with_comments"
  tasks_with_subtasks=$(jq -s '.' "$tmp_dir"/task_*.json)
fi

echo "" >&2
echo "Grouping by assignee..." >&2

# 使用 jq 依負責人分組並產出最終 JSON
# 轉換重點：
# 1) group_by(.assignee.name // "Unassigned")：依負責人名稱分組（無負責人視為 Unassigned）
# 2) map(...)：將每個分組轉換成統計+任務清單的物件
# 3) tasks 欄位內再做扁平化與欄位整理（custom_fields / subtasks / comments）
# 4) sort_by(.assignee.name)：排序負責人名稱
# 5) 包裝 metadata（Sprint 資訊、時間、總數統計）
final_json=$(echo "$tasks_with_subtasks" | jq --arg sprint_name "$sprint_name" --arg sprint_gid "$sprint_gid" '
  # Group by assignee name
  group_by(.assignee.name // "Unassigned") |

  # Transform each group
  map({
    assignee: {
      name: (.[0].assignee.name // "Unassigned"),
      gid: (.[0].assignee.gid // null),
      email: (.[0].assignee.email // null)
    },
    task_count: length,
    completed_count: [.[] | select(.completed == true)] | length,
    open_count: [.[] | select(.completed == false)] | length,
    tasks: [.[] | {
      gid: .gid,
      name: .name,
      completed: .completed,
      notes: .notes,
      due_on: .due_on,
      start_on: .start_on,
      created_at: .created_at,
      modified_at: .modified_at,
      permalink_url: .permalink_url,
      tags: [(.tags // [])[] | .name],
      custom_fields: [(.custom_fields // [])[] | {
        name: .name,
        value: (.display_value // .enum_value.name // null)
      }] | map(select(.value != null)),
      subtasks: [(.subtasks // [])[] | {
        gid: .gid,
        name: .name,
        completed: .completed,
        notes: .notes,
        due_on: .due_on,
        assignee: (.assignee.name // "Unassigned")
      }],
      comments: (.comments // [])
    }]
  }) |

  # Sort by assignee name
  sort_by(.assignee.name) |

  # Wrap in metadata
  {
    metadata: {
      sprint: {
        name: $sprint_name,
        gid: $sprint_gid
      },
      exported_at: (now | todate),
      total_tasks: (map(.task_count) | add),
      total_completed: (map(.completed_count) | add),
      total_open: (map(.open_count) | add),
      assignee_count: length
    },
    assignees: .
  }
')

# 依負責人寫入個別 JSON 檔案
assignee_count=$(echo "$final_json" | jq '.assignees | length')
for (( i=0; i<assignee_count; i++ )); do
  a_name=$(echo "$final_json" | jq -r ".assignees[$i].assignee.name")
  safe_name=$(echo "$a_name" | sed 's|/|-|g; s|[:\\]|_|g')
  echo "$final_json" | jq ".metadata as \$meta | .assignees[$i] | {metadata: \$meta} + ." > "${output_dir}/${safe_name}.json"
done

echo "Exported to: ${output_dir}/" >&2

# 以 jq 生成摘要文字（供 stderr 顯示）
# 轉換邏輯：從 metadata 取總數，並逐位列出每位負責人的任務統計
echo "" >&2
echo "=== Summary ===" >&2
echo "$final_json" | jq -r '
  "Sprint: \(.metadata.sprint.name)",
  "Total tasks: \(.metadata.total_tasks)",
  "Completed: \(.metadata.total_completed)",
  "Open: \(.metadata.total_open)",
  "Assignees: \(.metadata.assignee_count)",
  "",
  "By Assignee:",
  (.assignees[] | "  - \(.assignee.name): \(.task_count) tasks (\(.completed_count) done, \(.open_count) open)")
' >&2

# 產生 per-assignee Markdown 報告（預設啟用）
if [[ "$generate_markdown" == "true" ]]; then
  echo "" >&2
  echo "Generating Markdown reports..." >&2

  for (( i=0; i<assignee_count; i++ )); do
    a_name=$(echo "$final_json" | jq -r ".assignees[$i].assignee.name")
    safe_name=$(echo "$a_name" | sed 's|/|-|g; s|[:\\]|_|g')

    jq -r '
      "# Sprint Report: \(.metadata.sprint.name)\n",
      "> Exported: \(.metadata.exported_at)\n",

      "## \(.assignee.name)",
      (if .assignee.email then "_\(.assignee.email)_" else "" end),
      "",
      "**Tasks: \(.task_count)** | ✅ \(.completed_count) done | 🔄 \(.open_count) open",
      "",

      # Open tasks
      (if .open_count > 0 then
        "### 🔄 Open Tasks (\(.open_count))\n",
        (.tasks[] | select(.completed == false) |
          "- [ ] **\(.name)**",
          (if .permalink_url then "  - 🔗 [\(.permalink_url)](\(.permalink_url))" else empty end),
          (if .due_on then "  - 📅 Due: \(.due_on)" else empty end),
          (if .notes and .notes != "" then "  - 📝 Description:", "    > \(.notes | gsub("\n"; "\n    > ") | if length > 500 then .[0:500] + "..." else . end)" else empty end),
          (if (.custom_fields | length) > 0 then
            "  - 🏷️ Custom Fields:",
            (.custom_fields[] | "    - **\(.name)**: \(.value)")
          else empty end),
          (if (.subtasks | length) > 0 then
            "  - 📎 Subtasks (\(.subtasks | length)):",
            (.subtasks[] | "    - [\(if .completed then "x" else " " end)] \(.name)\(if .assignee and .assignee != "Unassigned" then " (@\(.assignee))" else "" end)")
          else empty end),
          (if (.comments | length) > 0 then
            "  - 💬 Comments (\(.comments | length)):",
            (.comments[] | "    - **\(.author)** (\(.created_at | split("T")[0])):", "      > \(.text | gsub("\n"; "\n      > "))")
          else empty end),
          ""
        )
      else empty end),

      # Completed tasks
      (if .completed_count > 0 then
        "### ✅ Completed Tasks (\(.completed_count))\n",
        (.tasks[] | select(.completed == true) |
          "- [x] ~~\(.name)~~",
          (if .permalink_url then "  - 🔗 [\(.permalink_url)](\(.permalink_url))" else empty end),
          (if .due_on then "  - 📅 Due: \(.due_on)" else empty end),
          (if .notes and .notes != "" then "  - 📝 Description:", "    > \(.notes | gsub("\n"; "\n    > ") | if length > 500 then .[0:500] + "..." else . end)" else empty end),
          (if (.custom_fields | length) > 0 then
            "  - 🏷️ Custom Fields:",
            (.custom_fields[] | "    - **\(.name)**: \(.value)")
          else empty end),
          (if (.subtasks | length) > 0 then
            "  - 📎 Subtasks (\(.subtasks | length)):",
            (.subtasks[] | "    - [\(if .completed then "x" else " " end)] \(.name)\(if .assignee and .assignee != "Unassigned" then " (@\(.assignee))" else "" end)")
          else empty end),
          (if (.comments | length) > 0 then
            "  - 💬 Comments (\(.comments | length)):",
            (.comments[] | "    - **\(.author)** (\(.created_at | split("T")[0])):", "      > \(.text | gsub("\n"; "\n      > "))")
          else empty end),
          ""
        ),
        ""
      else empty end)
    ' "${output_dir}/${safe_name}.json" > "${output_dir}/${safe_name}.md"
  done

  echo "Markdown exported to: ${output_dir}/" >&2
fi

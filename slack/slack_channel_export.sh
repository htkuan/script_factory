#!/usr/bin/env bash
# 嚴格模式 — -e: 指令失敗立即終止; -u: 使用未定義變數報錯; -o pipefail: 管線中任一指令失敗則整條管線失敗
set -euo pipefail

# 取得腳本所在的絕對路徑（無論從哪裡執行都能正確定位）
readonly SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Skill 根目錄（腳本位於 scripts/ 子目錄內，上一層即為 skill root）
readonly SKILL_DIR="$(cd "$SCRIPTDIR/.." && pwd)"
# 專案根目錄（透過 git 定位，fallback 為相對路徑推算）
readonly PROJECT_ROOT="$(cd "$SCRIPTDIR" && git rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPTDIR/../../../.." && pwd))"
# 最終輸出根目錄（放在專案根目錄下的 slack_data/）
readonly OUTPUT_DIR="$PROJECT_ROOT/slack_data"
# map 型快取資料目錄（使用者/群組/頻道對照表）
readonly CACHE_DIR="$OUTPUT_DIR/cache_data"

# ── Helper functions ──

# 檢查指定的命令列工具是否存在，不存在則報錯退出。用於確保 curl、jq、sed、date 等必要工具可用
require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command '$1' not found." >&2
    exit 1
  fi
}

# 檢查指定的檔案是否存在，不存在則報錯退出。用於確保設定檔和 Stage 1 產出的資料檔都存在
require_file() {
  if [[ ! -f "$1" ]]; then
    echo "Error: required file '$1' not found." >&2
    exit 1
  fi
}

# 將字串中的 &、/、\ 加上反斜線跳脫，避免在 sed 替換表達式中被誤解為特殊字元（使用者名稱可能包含這些字元）
escape_sed_repl() {
  printf '%s' "$1" | sed -e 's/[&/\\]/\\&/g'
}

# 驗證日期格式為 YYYY-MM-DD 且為合法日期（使用 macOS date -j 解析）
validate_date() {
  local label="$1" value="$2"
  if ! [[ "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "Error: $label '$value' is not in YYYY-MM-DD format." >&2
    exit 1
  fi
  # round-trip 驗證：macOS date -j 會把 02-30 自動溢位成 03-02，透過轉回字串比對確認日期合法
  local parsed
  parsed=$(date -j -f "%Y-%m-%d" "$value" "+%Y-%m-%d" 2>/dev/null) || {
    echo "Error: $label '$value' is not a valid date." >&2
    exit 1
  }
  if [[ "$parsed" != "$value" ]]; then
    echo "Error: $label '$value' is not a valid date (overflow to $parsed)." >&2
    exit 1
  fi
}

# 驗證設定檔中的必要欄位：slack_token、channels
# 注意：SLACK_TOKEN 在此函數之後於腳本層級設定（見 main 段落）
validate_config() {
  local token
  token=$(jq -r '.slack_token // empty' "$CONFIG_FILE")
  if [[ -z "$token" ]]; then
    echo "Error: slack_token missing in $CONFIG_FILE" >&2
    exit 1
  fi

  local channel_count
  channel_count=$(jq '.channels | length' "$CONFIG_FILE")
  if [[ "$channel_count" -le 0 ]]; then
    echo "Error: channels list is empty in $CONFIG_FILE" >&2
    exit 1
  fi

  echo "Config validated: $CONFIG_FILE"
  echo "  Period: $START_DATE ~ $END_DATE"
  echo "  Channels: $channel_count"
}

# Slack API 呼叫封裝，具備速率限制自動重試機制。組裝 URL 後用 curl 帶 Authorization: Bearer header 發送 GET 請求。-D 參數把回應標頭存到暫存檔，用於讀取 Retry-After。若 API 回傳 ratelimited，從標頭讀取等待秒數（預設 5 秒），最多重試 5 次
slack_api() {
  local endpoint="$1"
  local query="${2:-}"
  local url="https://slack.com/api/$endpoint"
  if [[ -n "$query" ]]; then
    url="$url?$query"
  fi
  local max_retries=5
  local attempt=0
  local body=""
  while [[ $attempt -lt $max_retries ]]; do
    local tmp_headers
    tmp_headers=$(mktemp)
    body=$(curl -sS -D "$tmp_headers" -H "Authorization: Bearer $SLACK_TOKEN" "$url")
    if echo "$body" | jq -e '.error == "ratelimited"' >/dev/null 2>&1; then
      local retry_after
      retry_after=$(grep -i '^retry-after:' "$tmp_headers" 2>/dev/null | tr -d '\r\n' | sed 's/^[^:]*: *//')
      if ! [[ "$retry_after" =~ ^[0-9]+$ ]]; then
        retry_after=5
      fi
      echo "  Rate limited, waiting ${retry_after}s..." >&2
      sleep "$retry_after"
      attempt=$((attempt + 1))
      rm -f "$tmp_headers"
    else
      rm -f "$tmp_headers"
      echo "$body"
      return 0
    fi
  done
  echo "$body"
}

# 檢查 Slack API 回應中 .ok 是否為 true，若不是則提取 .error 欄位顯示錯誤訊息並終止腳本
check_ok() {
  local response="$1"
  if ! echo "$response" | jq -e '.ok == true' >/dev/null 2>&1; then
    local err
    err=$(echo "$response" | jq -r '.error // "unknown_error"')
    echo "Error: Slack API call failed: $err" >&2
    exit 1
  fi
}

# ── Stage 1：從 Slack API 抓取資料並存為 JSON。包含使用者對照表、群組對照表、頻道對照表，以及各頻道的訊息（含討論串回覆） ──

stage1_fetch() {
  echo "=== Stage 1: Fetching data from Slack API ==="

  require_cmd curl

  # 將日期字串轉為 Unix timestamp（使用 macOS 的 date -j 語法，不相容 Linux）。END_TS 設為當天 23:59:59，確保包含結束日期的整天
  START_TS=$(date -j -f "%Y-%m-%d" "$START_DATE" "+%s")
  END_TS=$(date -j -f "%Y-%m-%d %H:%M:%S" "$END_DATE 23:59:59" "+%s")
  if [[ "$START_TS" -gt "$END_TS" ]]; then
    echo "Error: start_date is after end_date." >&2
    exit 1
  fi

  # 建立快取目錄
  mkdir -p "$CACHE_DIR"

  # 建立暫存目錄（用於分頁合併的中間檔案），註冊到統一清理陣列
  local tmpdir
  tmpdir=$(mktemp -d)
  _cleanup_dirs+=("$tmpdir")

  # 建立使用者對照表：呼叫 users.list API，cursor-based pagination 翻頁，每次最多 200 筆。最終用 jq reduce 轉為 { UXXXXX: 顯示名稱 } 格式。名稱優先順序：display_name > real_name > name > unknown
  # ── User map ──
  echo "Building user map..."
  local users_file="$tmpdir/users.json"
  echo '[]' > "$users_file"

  local cursor=""
  while :; do
    response=$(slack_api "users.list" "limit=200&cursor=$cursor")
    check_ok "$response"
    echo "$response" | jq '.members' > "$tmpdir/chunk.json"
    jq -s '.[0] + .[1]' "$users_file" "$tmpdir/chunk.json" > "$tmpdir/merge.json"
    mv "$tmpdir/merge.json" "$users_file"
    cursor=$(echo "$response" | jq -r '.response_metadata.next_cursor // ""')
    [[ -z "$cursor" ]] && break
    echo "  more users..."
    sleep 1
  done

  jq 'reduce .[] as $u ({}; .[$u.id] = (
    if ($u.profile.display_name // "") != "" then $u.profile.display_name
    elif ($u.real_name // "") != "" then $u.real_name
    elif ($u.name // "") != "" then $u.name
    else "unknown" end
  ))' "$users_file" > "$CACHE_DIR/user_map.json"
  echo "  Saved $(jq 'length' "$CACHE_DIR/user_map.json") users → cache_data/user_map.json"

  # 建立群組對照表：呼叫 usergroups.list API，建立 { SXXXXX: group_handle } 格式。用於後續將 subteam 標記替換成 @group_handle
  # ── Usergroup map ──
  echo "Building usergroup map..."
  local usergroups_file="$tmpdir/usergroups.json"
  echo '[]' > "$usergroups_file"

  cursor=""
  while :; do
    response=$(slack_api "usergroups.list" "include_disabled=true&include_count=false&include_users=false&cursor=$cursor")
    check_ok "$response"
    echo "$response" | jq '.usergroups' > "$tmpdir/chunk.json"
    jq -s '.[0] + .[1]' "$usergroups_file" "$tmpdir/chunk.json" > "$tmpdir/merge.json"
    mv "$tmpdir/merge.json" "$usergroups_file"
    cursor=$(echo "$response" | jq -r '.response_metadata.next_cursor // ""')
    [[ -z "$cursor" ]] && break
    echo "  more usergroups..."
    sleep 1
  done

  jq 'reduce .[] as $g ({}; .[$g.id] = ($g.handle // $g.name // "unknown"))' "$usergroups_file" > "$CACHE_DIR/usergroup_map.json"
  echo "  Saved $(jq 'length' "$CACHE_DIR/usergroup_map.json") usergroups → cache_data/usergroup_map.json"

  # 建立頻道對照表：呼叫 conversations.list API（公開與私有頻道）。產出兩個檔案：channel_name_to_id.json（名稱→ID）和 channel_id_to_name.json（ID→名稱）
  # ── Channel map ──
  echo "Building channel map..."
  local channels_file="$tmpdir/channels.json"
  echo '[]' > "$channels_file"

  cursor=""
  while :; do
    response=$(slack_api "conversations.list" "exclude_archived=true&types=public_channel,private_channel&limit=200&cursor=$cursor")
    check_ok "$response"
    echo "$response" | jq '.channels' > "$tmpdir/chunk.json"
    jq -s '.[0] + .[1]' "$channels_file" "$tmpdir/chunk.json" > "$tmpdir/merge.json"
    mv "$tmpdir/merge.json" "$channels_file"
    cursor=$(echo "$response" | jq -r '.response_metadata.next_cursor // ""')
    [[ -z "$cursor" ]] && break
    echo "  more channels..."
    sleep 1
  done

  jq 'reduce .[] as $c ({}; .[$c.name] = $c.id)' "$channels_file" > "$CACHE_DIR/channel_name_to_id.json"
  jq 'reduce .[] as $c ({}; .[$c.id] = $c.name)' "$channels_file" > "$CACHE_DIR/channel_id_to_name.json"
  echo "  Saved $(jq 'length' "$CACHE_DIR/channel_name_to_id.json") channels → cache_data/channel_*.json"

  # 逐一抓取設定檔中指定的頻道訊息
  # ── Fetch messages per channel ──
  local channel_names=()
  while IFS= read -r line; do
    channel_names+=("$line")
  done < <(jq -r '.channels[]' "$CONFIG_FILE")

  for raw_name in "${channel_names[@]}"; do
    # 去掉頻道名稱可能的 # 前綴，從對照表查找對應的 channel ID
    local name="${raw_name#\#}"
    local channel_id
    channel_id=$(jq -r --arg name "$name" '.[$name] // empty' "$CACHE_DIR/channel_name_to_id.json")
    if [[ -z "$channel_id" ]]; then
      echo "Warning: could not resolve channel '$raw_name', skipping." >&2
      continue
    fi

    echo "Fetching #$name ($channel_id)..."
    local messages_file="$tmpdir/messages.json"
    echo '[]' > "$messages_file"

    # 拉取頻道歷史訊息
    cursor=""
    local channel_failed=false
    while :; do
      # 呼叫 conversations.history 帶上 oldest/latest 時間範圍，cursor-based pagination 翻頁。若 bot 未被邀請進頻道則跳過（不終止腳本）
      response=$(slack_api "conversations.history" "channel=$channel_id&limit=200&oldest=$START_TS&latest=$END_TS&inclusive=true&cursor=$cursor")
      if ! echo "$response" | jq -e '.ok == true' >/dev/null 2>&1; then
        local hist_err
        hist_err=$(echo "$response" | jq -r '.error // "unknown"')
        echo "  Error: could not read #$name ($hist_err). Is the bot in the channel?" >&2
        channel_failed=true
        break
      fi
      echo "$response" | jq '.messages' > "$tmpdir/chunk.json"
      jq -s '.[0] + .[1]' "$messages_file" "$tmpdir/chunk.json" > "$tmpdir/merge.json"
      mv "$tmpdir/merge.json" "$messages_file"
      cursor=$(echo "$response" | jq -r '.response_metadata.next_cursor // ""')
      [[ -z "$cursor" ]] && break
      echo "  more messages..."
      sleep 1
    done

    if [[ "$channel_failed" == "true" ]]; then
      continue
    fi

    # 抓取討論串回覆：篩出有 thread_ts 且 reply_count > 0 的根訊息，對每個討論串呼叫 conversations.replies。過濾掉根訊息本身避免重複
    # Fetch thread replies
    local thread_ts_list
    thread_ts_list=$(jq -r '.[] | select(.thread_ts and (.ts != .thread_ts or (.reply_count // 0) > 0)) | .thread_ts' "$messages_file" | sort -u)
    for thread_ts in $thread_ts_list; do
      cursor=""
      while :; do
        response=$(slack_api "conversations.replies" "channel=$channel_id&ts=$thread_ts&limit=200&cursor=$cursor")
        check_ok "$response"
        echo "$response" | jq '.messages' > "$tmpdir/chunk.json"
        jq -s '.[0] + .[1]' "$messages_file" "$tmpdir/chunk.json" > "$tmpdir/merge.json"
        mv "$tmpdir/merge.json" "$messages_file"
        cursor=$(echo "$response" | jq -r '.response_metadata.next_cursor // ""')
        [[ -z "$cursor" ]] && break
        echo "  more replies for thread $thread_ts..."
        sleep 1
      done
    done

    # 按 timestamp 排序、用 unique_by(.ts) 去除重複訊息，存為最終 JSON 檔
    # Sort, deduplicate, save final JSON
    local channel_out_dir="$OUTPUT_DIR/${name}/${START_DATE}_${END_DATE}"
    mkdir -p "$channel_out_dir"
    jq 'unique_by(.ts) | sort_by([(.thread_ts // .ts | tonumber), (.ts | tonumber)])' "$messages_file" > "$channel_out_dir/${name}_${START_DATE}_${END_DATE}.json"
    local msg_count
    msg_count=$(jq 'length' "$channel_out_dir/${name}_${START_DATE}_${END_DATE}.json")
    echo "  Saved $msg_count messages → ${name}/${START_DATE}_${END_DATE}/${name}_${START_DATE}_${END_DATE}.json"
  done

  echo "=== Stage 1 complete. JSON data saved in $OUTPUT_DIR ==="
}

# ── Stage 2：將 JSON 資料轉換為人類可讀的 Markdown 格式。先用 jq 產生原始 Markdown，再用 sed 將 Slack ID 標記替換為真實名稱 ──

stage2_convert() {
  echo ""
  echo "=== Stage 2: Converting JSON → Markdown ==="

  local start_date="$START_DATE"
  local end_date="$END_DATE"

  require_file "$CACHE_DIR/user_map.json"
  require_file "$CACHE_DIR/usergroup_map.json"
  require_file "$CACHE_DIR/channel_id_to_name.json"

  # 建立暫存目錄（用於 Markdown 轉換的中間檔案與 sed 腳本），註冊到統一清理陣列
  local tmpdir
  tmpdir=$(mktemp -d)
  _cleanup_dirs+=("$tmpdir")

  # 讀取設定檔中的頻道列表
  local channel_names=()
  while IFS= read -r line; do
    channel_names+=("$line")
  done < <(jq -r '.channels[]' "$CONFIG_FILE")

  for raw_name in "${channel_names[@]}"; do
    local name="${raw_name#\#}"
    local channel_out_dir="$OUTPUT_DIR/${name}/${start_date}_${end_date}"
    local json_file="$channel_out_dir/${name}_${start_date}_${end_date}.json"

    if [[ ! -f "$json_file" ]]; then
      echo "Warning: no JSON data for #$name ($json_file), skipping." >&2
      continue
    fi

    echo "Converting #$name → Markdown..."

    # tsfmt: 將 Unix timestamp 格式化為 YYYY-MM-DD HH:MM:SS
    # usertag: 產生發送者標記（此時還是 ID，後續 sed 會替換為真實名稱）
    # is_reply: 判斷訊息是否為討論串回覆（thread_ts 存在且不等於自己的 ts）
    # first_replies: 記錄每個討論串的第一條回覆的 ts，用於區分顯示樣式
    # 一般訊息：sender (timestamp) + 內容 + 分隔線
    # 討論串第一條回覆：無分隔線，視覺上連接到原訊息
    # 討論串後續回覆：用 blockquote 縮排表示
    # ── jq: JSON → raw Markdown ──
    local markdown_tmp="$tmpdir/${name}.md"
    jq -r '
      def tsfmt: (.ts | tonumber | strftime("%Y-%m-%d %H:%M:%S"));
      def usertag:
        if .user then "**" + .user + "**"
        elif .bot_id and .username then "**" + .username + "**"
        elif .username then "**" + .username + "**"
        else "**unknown**" end;
      def is_reply: (.thread_ts and .ts != .thread_ts);
      def render_files:
        if .files then
          "\n" + ([.files[] | "[File: \(.name // "unnamed")](\(.permalink // .url_private // ""))"] | join("\n"))
        else "" end;
      def render_attachments:
        if .attachments then
          "\n" + ([.attachments[] |
            (if .title and .title_link then "[\(.title)](\(.title_link))"
             elif .title then .title
             else "" end) +
            (if .text then "\n" + .text else "" end)
          ] | map(select(. != "")) | join("\n"))
        else "" end;
      def content: (.text // "") + render_files + render_attachments;

      sort_by([(.thread_ts // .ts | tonumber), (.ts | tonumber)]) as $sorted
      | ($sorted | reduce .[] as $msg (
          {};
          if ($msg.thread_ts and $msg.ts != $msg.thread_ts and (has($msg.thread_ts) | not)) then
            . + {($msg.thread_ts): $msg.ts}
          else . end
        )) as $first_replies
      | $sorted[]
      | if is_reply then
          if ($first_replies[.thread_ts] == .ts) then
            usertag + " (" + tsfmt + ")\n" + content
          else
            "> " + usertag + " (" + tsfmt + ")\n> " + (content | split("\n") | join("\n> "))
          end
        else
          usertag + " (" + tsfmt + ")\n" + content + "\n\n---"
        end
    ' "$json_file" > "$markdown_tmp"

    # 建立 sed 替換腳本，將 Slack 的各種特殊標記轉為 Markdown 可讀格式
    # ── Build sed replacement script ──
    local sed_script="$tmpdir/replacements.sed"
    : > "$sed_script"

    # 使用者 mention: <@U12345> 或 <@U12345|name> → **@真實名稱**
    # User mention: <@UXXXX> → **@real_name**
    while IFS=$'\t' read -r id name_value; do
      [[ -z "$id" ]] && continue
      local safe_name
      safe_name=$(escape_sed_repl "$name_value")
      echo "s/<@${id}(\\|[^>]+)?>/**@${safe_name}**/g" >> "$sed_script"
    done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' "$CACHE_DIR/user_map.json")

    # 發送者 ID: **U12345** → **真實名稱**
    # Sender field: **UXXXX** → **real_name**
    while IFS=$'\t' read -r id name_value; do
      [[ -z "$id" ]] && continue
      local safe_name
      safe_name=$(escape_sed_repl "$name_value")
      echo "s/\\*\\*${id}\\*\\*/**${safe_name}**/g" >> "$sed_script"
    done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' "$CACHE_DIR/user_map.json")

    # 群組 mention: <!subteam^S12345> → **@group_handle**
    # Usergroup mention: <!subteam^SXXXX> → **@group_name**
    while IFS=$'\t' read -r id handle; do
      [[ -z "$id" ]] && continue
      local safe_handle
      safe_handle=$(escape_sed_repl "$handle")
      echo "s/<!subteam\\^${id}(\\|[^>]+)?>/\*\*@${safe_handle}\*\*/g" >> "$sed_script"
    done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' "$CACHE_DIR/usergroup_map.json")

    # 頻道 mention（帶名稱）: <#C12345|general> → #general
    # Channel mention: <#CXXXX|name> → #name
    echo 's/<#[A-Z0-9]+\|([^>]+)>/#\1/g' >> "$sed_script"

    # 頻道 mention（純 ID）: <#C12345> → #general
    # Channel ID without display name: <#CXXXX> → #channel_name
    while IFS=$'\t' read -r id channel_name; do
      [[ -z "$id" ]] && continue
      local safe_channel
      safe_channel=$(escape_sed_repl "$channel_name")
      echo "s/<#${id}>/#${safe_channel}/g" >> "$sed_script"
    done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' "$CACHE_DIR/channel_id_to_name.json")

    # 超連結: <url|text> → [text](url)
    # Hyperlinks: <url|text> → [text](url)
    echo 's/<(https?:\/\/[^>|]+)\|([^>]+)>/[\2](\1)/g' >> "$sed_script"

    # 純 URL: <url> → url
    # Bare URLs: <url> → url
    echo 's/<(https?:\/\/[^>]+)>/\1/g' >> "$sed_script"

    # Slack 粗體: *text* → **text**（只轉換單星號，不影響已有的雙星號）
    # Slack bold *text* → **text** (only single *, not already **)
    echo 's/([^*]|^)\*([^*]+)\*/\1**\2**/g' >> "$sed_script"

    # HTML entity 解碼：Slack API 回傳的文字會將 &、<、> 編碼為 HTML entity，需還原。&amp; 必須最後替換，避免二次解碼
    # HTML entity decode: &lt; → <, &gt; → >, &amp; → & (amp last to avoid double-decoding)
    echo 's/&lt;/</g' >> "$sed_script"
    echo 's/&gt;/>/g' >> "$sed_script"
    echo 's/&amp;/\&/g' >> "$sed_script"

    # 組裝最終 Markdown：在內容前加上中文標題和時間區間，然後通過 sed -E -f 套用所有替換規則，輸出最終 .md 檔
    # ── Assemble and apply sed ──
    local output_tmp="$tmpdir/${name}.md.tmp"
    local output_file="$channel_out_dir/${name}_${start_date}_${end_date}.md"

    {
      echo "# #${name} 對話紀錄"
      echo "> 時間區間：${start_date} ~ ${end_date}"
      echo ""
      cat "$markdown_tmp"
    } > "$output_tmp"

    sed -E -f "$sed_script" "$output_tmp" > "$output_file"

    echo "  Saved → ${name}/${start_date}_${end_date}/${name}_${start_date}_${end_date}.md"
  done

  echo "=== Stage 2 complete. Markdown saved in $OUTPUT_DIR ==="
}

# ── Main ──

# 前置檢查：確認 jq、sed、date 三個必要工具都已安裝
require_cmd jq
require_cmd sed
require_cmd date

# 解析命令列參數：start_date（必填）、end_date（必填）
# 設定檔固定讀取腳本同目錄下的 config.json
# 注意：此腳本使用 macOS 專用的 date -j 語法，需要 Slack Bot Token（xoxb- 開頭），且 bot 必須已被邀請進目標頻道
if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <start_date> <end_date>" >&2
  echo "  start_date — 起始日期 (YYYY-MM-DD)" >&2
  echo "  end_date   — 結束日期 (YYYY-MM-DD)" >&2
  echo "  config     — 自動讀取 ./config.json (slack_token, channels)" >&2
  exit 1
fi

readonly START_DATE="$1"
readonly END_DATE="$2"

validate_date "start_date" "$START_DATE"
validate_date "end_date" "$END_DATE"

readonly CONFIG_FILE="$SKILL_DIR/config.json"
require_file "$CONFIG_FILE"

validate_config
# 驗證通過後，在腳本層級設定 SLACK_TOKEN（供 slack_api 函數使用）
readonly SLACK_TOKEN=$(jq -r '.slack_token // empty' "$CONFIG_FILE")

# 統一清理機制：各階段透過 _cleanup_dirs+=(...) 註冊暫存目錄，腳本結束時一次清除
_cleanup_dirs=()
_cleanup() {
  for d in "${_cleanup_dirs[@]}"; do
    rm -rf "$d"
  done
}
trap _cleanup EXIT

stage1_fetch
stage2_convert

echo ""
echo "Done."

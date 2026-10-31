#!/usr/bin/env bash
# 调查面名单的一致性检查（模型 ↔ agentd ↔ 网关）。
#
# 为什么需要它：调查面的"事实"目前分散在三处 ——
#   * 模型：jumo/model/static/control/module/agent/investigation/items.mju 的 `variant InvestigationSurface`
#   * agentd：src/investigate.rs 的 `pub const TOPICS`（实现了哪些题）
#   * 网关 / web：各自的 `TOPICS` 常量（菜单与入队前校验）
# 三份名单漂移的后果是静默的：页面上少一个题、或者下发后回 `unsupported`。
#
# 规则：
#   * 模型 ↔ agentd：**必须相等**，不等即退出码 1（模型是定义，agentd 是事实）。
#   * 模型 ↔ 网关：只报告（网关可以落后一个发布周期；它还要改页面）。
#
# 用法（各仓并排检出时）：
#   scripts/check-investigation-surfaces.sh [agentd 路径] [gateway 路径] [web 路径]
#   # 默认 ../wist/wist-agentd、../wist/wist-gateway、../wist/wist-gateway-web
#   # （wist-design 与 wist/ 平级）
#
# 退出码：0 = 模型与 agentd 一致（网关/web 差异只打印）；1 = 模型与 agentd 不一致；2 = 环境不完整。
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
AGENTD=${1:-"$ROOT/../wist/wist-agentd"}
GATEWAY=${2:-"$ROOT/../wist/wist-gateway"}
WEB=${3:-"$ROOT/../wist/wist-gateway-web"}
MODEL="$ROOT/jumo/model/static/control/module/agent/investigation/items.mju"

fail=0
pass() { printf 'PASS  %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; fail=1; }
note() { printf '      %s\n' "$*"; }

if [ ! -f "$MODEL" ]; then
  printf 'ENV   模型不存在: %s\n' "$MODEL"
  exit 2
fi

# variant 的取值 → 协议 id（Accounts → accounts）。
# 协议 id 是**契约**（命令 params、finding.id 前缀、审计、历史报告），
# 所以命名约定的机械转换只做默认值，例外在这里显式列出。
# 注意：必须带换行 —— 下一个环节按行收 id，不带换行会拼成 `diskloadaccounts…`。
to_id() {
  case "$1" in
    # 面 id 带连字符（`telemetry-health`），而它的节前缀是 `telemetry.`。
    TelemetryHealth) printf 'telemetry-health\n'; return ;;
  esac
  printf '%s' "$1" | sed -E 's/([a-z0-9])([A-Z])/\1_\2/g' | tr '[:upper:]' '[:lower:]'
  printf '\n'
}

# 从 variant 体里取取值：跳过 `meta { … }` 块与 `//` 注释，按空白切词。
model_ids() {
  awk '
    /^variant InvestigationSurface \{/ { inside=1; next }
    inside && /^\}/ { inside=0 }
    inside {
      line=$0
      sub(/\/\/.*/, "", line)
      if (line ~ /^[ \t]*$/) next
      if (line ~ /^[ \t]*meta[ \t]*\{/) { meta=1; next }
      if (meta && line ~ /^[ \t]*\}/) { meta=0; next }
      if (meta) next
      print line
    }
  ' "$MODEL" |
    tr -s ' \t' '\n' |
    sed '/^$/d' |
    while read -r case_name; do to_id "$case_name"; done |
    sort -u
}

# 从源码里取 `const TOPICS` 的取值。两种写法都要支持：
#   agentd：&[TOPIC_DISK, TOPIC_LOAD, …]（先取常量名，再回查各自的字符串）；
#   网关：  &["disk", "load"]（字面量）。
code_ids() {
  local file=$1
  [ -f "$file" ] || return 1
  local block names
  # 结束条件写成“以 `]` 开头的行”：agentd / 网关是 `];`，web 是 `] as const;`。
  # 用 `/];/` 在 web 上匹配不到，会一路读到文件尾，把正文里的字符串也当成 id。
  block=$(awk '/const TOPICS/{inside=1} inside{print} inside && /^\]/{exit}' "$file")
  names=$(printf '%s\n' "$block" | grep -oE 'TOPIC_[A-Z0-9_]+' | sort -u)
  if [ -z "$names" ]; then
    printf '%s\n' "$block" | grep -oE '"[a-z0-9_-]+"' | tr -d '"' | sort -u
    return 0
  fi
  while read -r name; do
    [ -z "$name" ] && continue
    sed -n "s/^pub const $name: &str = \"\([a-z0-9_-]*\)\";.*/\1/p" "$file"
  done <<<"$names" | sort -u
}

model=$(model_ids)
if [ -z "$model" ]; then
  bad "模型里没解析出任何调查面（variant InvestigationSurface 写法变了？）"
  exit 1
fi

# ── 模型 ↔ agentd（必须一致）────────────────────────────────────────
agentd_file="$AGENTD/src/investigate.rs"
if [ -f "$agentd_file" ]; then
  agentd=$(code_ids "$agentd_file")
  if [ "$model" = "$agentd" ]; then
    pass "模型 ↔ agentd 一致（$(printf '%s' "$model" | tr '\n' ' ')）"
  else
    bad "模型 ↔ agentd 不一致"
    diff <(printf '%s\n' "$model") <(printf '%s\n' "$agentd") |
      sed -E 's/^</  仅在模型:/; s/^>/  仅在 agentd:/' | sed '/^[0-9-]/d'
  fi
else
  printf 'SKIP 找不到 agentd（%s）\n' "$agentd_file"
fi

# ── 模型 ↔ 网关（只报告）────────────────────────────────────────────
gateway_file="$GATEWAY/src/api/investigations.rs"
if [ -f "$gateway_file" ]; then
  gateway=$(code_ids "$gateway_file")
  missing=$(comm -23 <(printf '%s\n' "$model") <(printf '%s\n' "$gateway"))
  if [ -z "$missing" ]; then
    pass "模型 ↔ 网关一致"
  else
    printf 'WARN 网关还没跟上：%s\n' "$(printf '%s' "$missing" | tr '\n' ' ')"
    note "加题时网关与 web 都要改常量（见 agentd 设计文档 §7），且先于知识库发布。"
  fi
else
  printf 'SKIP 找不到网关（%s）\n' "$gateway_file"
fi

# ── 模型 ↔ web（只报告：web 跟网关一起发布，可能落后一个周期）────────
# 两处常量都要看：授权面板与调查页各有一份（页面不应该自己维护第三份名单）。
web_files="$WEB/src/components/InvestigationGrantsPanel.tsx $WEB/src/components/SubsystemAgentInvestigationsPage.tsx"
web_missing=""
web_found=0
for web_file in $web_files; do
  [ -f "$web_file" ] || continue
  web_found=1
  web_ids=$(code_ids "$web_file")
  missing_one=$(comm -23 <(printf '%s\n' "$model") <(printf '%s\n' "$web_ids"))
  [ -n "$missing_one" ] && web_missing="$web_missing $missing_one"
done
if [ "$web_found" -eq 0 ]; then
  printf 'SKIP 找不到 web（%s）\n' "$WEB"
elif [ -z "$web_missing" ]; then
  pass "模型 ↔ web 一致"
else
  printf 'WARN web 还没跟上：%s\n' "$(printf '%s' "$web_missing" | tr '\n' ' ')"
  note "加题时两处 TOPICS 常量与题目名都要改（授权面板与调查页）。"
fi

exit "$fail"

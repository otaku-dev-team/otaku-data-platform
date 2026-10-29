#!/usr/bin/env bash
# 部署后冒烟：核心读路径 + 权限边界，30 秒出结论。
#
# 为什么要有这个：2026-10-29 23:10 发版时，application.yml 里 cover 段的
# allowed-hosts 被挤进 app.ugc 下，白名单变成空列表（fail-closed），
# 全站封面 404 了 55 分钟才被发现。当时只查了 /actuator/health——它永远是 UP，
# 因为配置错位不影响启动。这个脚本就是把「健康的假象」补上一条真实路径。
#
# 用法：
#   bash scripts/post-deploy-check.sh                      # 默认 127.0.0.1:8080（在服务器上跑）
#   bash scripts/post-deploy-check.sh http://154.8.194.198:8080
# 退出码：0 全过 / 1 有失败
set -uo pipefail

BASE="${1:-http://127.0.0.1:8080}"
FAILS=0
PASSES=0

pass() { PASSES=$((PASSES + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { FAILS=$((FAILS + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

# code <url> [extra curl args...] → 打印状态码
code() {
  local url="$1"; shift
  curl -s -o /dev/null -m 20 -w '%{http_code}' "$@" "$url" 2>/dev/null || echo "000"
}

echo "冒烟目标：$BASE"

echo "[1] 健康检查"
c=$(code "$BASE/actuator/health")
[ "$c" = "200" ] && pass "health 200" || fail "health 返回 $c"

echo "[2] 作品列表"
body=$(curl -s -m 20 "$BASE/api/works?page=1&page_size=1" 2>/dev/null || true)
total=$(printf '%s' "$body" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("total",0))' 2>/dev/null || echo 0)
if [ "${total:-0}" -gt 0 ]; then pass "列表 total=$total"; else fail "列表 total=$total（body: ${body:0:80}）"; fi

work_id=$(printf '%s' "$body" | python3 -c 'import json,sys;i=json.load(sys.stdin).get("items") or [{}];print(i[0].get("work_id",""))' 2>/dev/null || echo "")
cover_url=$(printf '%s' "$body" | python3 -c 'import json,sys;i=json.load(sys.stdin).get("items") or [{}];print(i[0].get("cover_url") or "")' 2>/dev/null || echo "")

echo "[3] 作品详情"
if [ -n "$work_id" ]; then
  c=$(code "$BASE/api/works/$work_id")
  [ "$c" = "200" ] && pass "详情 $work_id 200" || fail "详情 $work_id 返回 $c"
else
  fail "列表没取到 work_id"
fi

echo "[4] 标签词表"
c=$(code "$BASE/api/tags?limit=50")
[ "$c" = "200" ] && pass "tags 200" || fail "tags 返回 $c"

echo "[5] 封面代理（白名单失效时这里会 404）"
if [ -n "$cover_url" ]; then
  # cover_url 是绝对地址（可能指向别的 host），只取路径部分拼到 BASE 上
  path="/api/covers/$work_id"
  c=$(code "$BASE$path")
  if [ "$c" = "200" ]; then
    pass "封面 $work_id 200"
  else
    fail "封面 $work_id 返回 $c —— 检查 app.cover.allowed-hosts 是否还在 cover 段下"
  fi
else
  echo "  SKIP 列表首条无封面，换一条再验"
fi

echo "[6] 内部接口无令牌必须被拒"
c=$(code "$BASE/internal/import/batches/smoke-probe")
case "$c" in
  401|403|404) pass "内部接口无令牌返回 $c" ;;
  *) fail "内部接口无令牌返回 $c（应为 401/403/404）" ;;
esac

echo "[7] 指标端点公网不可读"
c=$(code "$BASE/actuator/prometheus")
[ "$c" = "401" ] && pass "prometheus 无令牌 401" || fail "prometheus 无令牌返回 $c（应为 401）"

echo
if [ "$FAILS" -eq 0 ]; then
  printf '\033[32m结论：%d 项通过，0 失败\033[0m\n' "$PASSES"
  exit 0
else
  printf '\033[31m结论：%d 项通过，%d 项失败\033[0m\n' "$PASSES" "$FAILS"
  exit 1
fi

#!/usr/bin/env bash
#
# 生产巡检。给 cron / systemd timer 调，也可以手动跑。
#
#   ./deploy/monitor.sh           # 逐项打印
#   ./deploy/monitor.sh --quiet   # 只在失败时说话（cron 用这个，别每天发一封"一切正常"）
#
# 查四件事，任一失败 → 退出码 1：
#
#   1. 健康检查     后端 /actuator/health 是否返回 UP
#   2. 容器状态     EXPECT_SERVICES 里的每个容器是否 healthy（有 docker 才查）
#   3. 磁盘占用     超过阈值就报——磁盘满是最常见的"服务莫名其妙挂了"
#   4. 备份新鲜度   最新备份必须 < 26 小时。备份停了但不报警 = 以为有备份
#
# 另外查两条不算失败的（只告警，不改变退出码）：
#
#   5. 证书剩余天数 HTTPS 静默过期那天，App 会突然全部连不上，而服务器本身"正常"
#   6. 慢查询日志体积 常开慢查询是为了「有据可查」，但没人看着它会默默涨大
#   7. 内存与 swap    2G 机器上挤着 mysql + java + 别的项目，available 见底就是 OOM 前兆
#
# 阈值都能用环境变量覆盖，默认值是按 2 核 2G / 50G 盘定的；
# 也可以在 .env 里写 EXPECT_SERVICES / EXPECT_TLS，切换"正式形态 / 联调形态"。
#
# 告警去哪了：这台机器**没有 MTA**，cron 把输出丢给 logger 之后就没有下文了
# ——也就是说"退出码非 0"这件事，默认只有 syslog 知道，没有人会收到邮件。
# 要真收到，在 .env 里配 ALERT_WEBHOOK（企业微信 / 钉钉机器人都吃同一种
# {"msgtype":"text"} 形状），失败时会 POST 一条。没配就每轮打一行 SKIP 提醒，
# 免得"以为有告警"这件事再被忘掉。

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(dirname "$SCRIPT_DIR")

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

read_env() {
    local key=$1 default=${2:-} file="$ROOT_DIR/.env" line val
    [ -f "$file" ] || { printf '%s' "$default"; return; }
    line=$(grep -E "^[[:space:]]*${key}=" "$file" | tail -1 || true)
    [ -n "$line" ] || { printf '%s' "$default"; return; }
    val=${line#*=}
    val=${val%\"}; val=${val#\"}
    val=${val%\'}; val=${val#\'}
    printf '%s' "${val:-$default}"
}

SITE_KEY=${SITE_KEY:-$(read_env SITE_KEY otaku)}
DOMAIN=${DOMAIN:-$(read_env DOMAIN "")}
BACKUP_DIR=${BACKUP_DIR:-$(read_env BACKUP_DIR /var/backups/otaku)}
HEALTH_URL=${HEALTH_URL:-http://127.0.0.1:8080/actuator/health}
DISK_PATH=${DISK_PATH:-/}
DISK_MAX_PCT=${DISK_MAX_PCT:-85}
BACKUP_MAX_AGE_H=${BACKUP_MAX_AGE_H:-26}
CERT_MIN_DAYS=${CERT_MIN_DAYS:-14}
COMPOSE_PROJECT=${COMPOSE_PROJECT:-otaku-prod}
# 该有哪些容器、要不要校验 TLS —— 都**显式**配，不让脚本猜。
# 为什么不用「没有就当没起过」的自动探测：那样 nginx 被误删/起不来也会被静默跳过，
# 巡检就变成了「什么都不查也报通过」。
#   正式形态（域名 + HTTPS）：保持默认，三个容器 + 校验证书
#   联调形态（IP + HTTP，nginx 未启用）：EXPECT_SERVICES="otaku-backend otaku-mysql" EXPECT_TLS=0
EXPECT_SERVICES=${EXPECT_SERVICES:-$(read_env EXPECT_SERVICES "otaku-backend otaku-mysql otaku-nginx")}
EXPECT_TLS=${EXPECT_TLS:-$(read_env EXPECT_TLS 1)}
# 告警 webhook：企业微信 / 钉钉机器人的地址（含 key，别提交进仓库）
ALERT_WEBHOOK=${ALERT_WEBHOOK:-$(read_env ALERT_WEBHOOK "")}
ALERT_TIMEOUT=${ALERT_TIMEOUT:-5}

FAILS=0
FAIL_LINES=""
say()  { [ "$QUIET" = "1" ] || printf '%s\n' "$*"; }
ok()   { say "[OK]   $*"; }
fail() {
    printf '[FAIL] %s\n' "$*" >&2
    FAILS=$((FAILS + 1))
    FAIL_LINES="${FAIL_LINES}${FAIL_LINES:+; }$*"
}
warn() { printf '[WARN] %s\n' "$*" >&2; }
skip() { say "[SKIP] $*"; }

# 发一条告警。没配 webhook 就只留一行提醒——不假装发出去了。
# URL 里带机器人 key，所以任何输出都只打 host，不打全量。
notify() {
    local text=$1 host payload masked
    [ -n "$ALERT_WEBHOOK" ] || { printf '[告警] 未配置 ALERT_WEBHOOK，这条只进了 syslog\n' >&2; return 0; }
    host=$(printf '%s' "$ALERT_WEBHOOK" | sed -E 's#^[a-z]+://([^/]+)/.*#\1#')
    masked="$host/…"
    # 换行在 JSON 里非法，统一压成 " | "；引号与反斜杠转义
    payload=$(printf '%s' "$text" | tr '\n' ' ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    if curl -fsS -m "$ALERT_TIMEOUT" -H 'Content-Type: application/json' \
            -d "{\"msgtype\":\"text\",\"text\":{\"content\":\"$payload\"}}" \
            "$ALERT_WEBHOOK" >/dev/null 2>&1; then
        printf '[告警] 已发送到 %s\n' "$masked" >&2
    else
        printf '[告警] 发送失败（%s），这条只剩 syslog\n' "$masked" >&2
    fi
}

# ── 1. 健康检查 ──────────────────────────────────────────────────────
# 用 curl 的退出码判断可达性，再单独看 status 字段：
# 只有 "连接上了但 status 不是 UP" 和 "根本连不上" 要区分开，否则排查时看不出方向。
if ! command -v curl >/dev/null 2>&1; then
    skip "健康检查（没有 curl）"
else
    BODY=$(curl -fsS --max-time 8 "$HEALTH_URL" 2>/dev/null) || BODY=""
    if [ -z "$BODY" ]; then
        fail "健康检查不可达：$HEALTH_URL"
    elif printf '%s' "$BODY" | grep -q '"status":"UP"'; then
        ok "健康检查 UP（$HEALTH_URL）"
    else
        fail "健康检查返回非 UP：$(printf '%s' "$BODY" | head -c 160)"
    fi
fi

# ── 2. 容器状态 ──────────────────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
    skip "容器状态（没有 docker CLI）"
else
    for c in $EXPECT_SERVICES; do
        STATE=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
                    "$c" 2>/dev/null) || STATE=""
        case "$STATE" in
            healthy|running) ok "容器 $c = $STATE" ;;
            "")              fail "容器 $c 不存在或未运行" ;;
            *)               fail "容器 $c = $STATE" ;;
        esac
    done
fi

# ── 3. 磁盘占用 ──────────────────────────────────────────────────────
if ! command -v df >/dev/null 2>&1; then
    skip "磁盘（没有 df）"
else
    PCT=$(df -P "$DISK_PATH" | awk 'NR==2 {gsub("%","",$5); print $5}')
    if [ -z "$PCT" ]; then
        fail "读不到磁盘占用：$DISK_PATH"
    elif [ "$PCT" -lt "$DISK_MAX_PCT" ]; then
        ok "磁盘 $DISK_PATH 已用 ${PCT}%（阈值 ${DISK_MAX_PCT}%）"
    else
        fail "磁盘 $DISK_PATH 已用 ${PCT}%，超过阈值 ${DISK_MAX_PCT}%"
    fi
fi

# ── 4. 备份新鲜度 ────────────────────────────────────────────────────
LATEST=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name "${SITE_KEY}-*.sql.gz" 2>/dev/null \
            -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
if [ -z "$LATEST" ]; then
    fail "备份目录里没有 ${SITE_KEY}-*.sql.gz：$BACKUP_DIR（备份从没成功过？）"
else
    AGE_H=$(( ( $(date +%s) - $(stat -c %Y "$LATEST") ) / 3600 ))
    if [ "$AGE_H" -lt "$BACKUP_MAX_AGE_H" ]; then
        ok "最新备份 $(basename "$LATEST")，${AGE_H}h 前（阈值 ${BACKUP_MAX_AGE_H}h）"
    else
        fail "最新备份 $(basename "$LATEST") 已 ${AGE_H}h 未更新（阈值 ${BACKUP_MAX_AGE_H}h）"
    fi
fi

# ── 5. 证书剩余天数（只告警，不计失败）────────────────────────────────
# 为什么不计失败：证书过期当天第 1 项和第 3 项都会炸，这条只是提前预警。
if [ "$EXPECT_TLS" = "0" ]; then
    skip "证书到期（EXPECT_TLS=0：当前是没有域名 / 没有 HTTPS 的联调形态）"
elif [ -z "$DOMAIN" ]; then
    skip "证书到期（.env 里没有 DOMAIN）"
elif ! command -v openssl >/dev/null 2>&1; then
    skip "证书到期（没有 openssl）"
else
    # 必须加超时：`openssl s_client` 默认会一直等，遇到「TCP 通但对端不说话」
    # （防火墙丢包、TLS 握手卡住）就会把整个巡检挂死——而 cron 里挂死等于没有巡检。
    # 没有 timeout 命令时退化为直接调，但至少给出可诊断的 WARN。
    TO=()
    command -v timeout >/dev/null 2>&1 && TO=(timeout 8)
    END=$(printf '' | "${TO[@]}" openssl s_client -connect "${DOMAIN}:443" -servername "$DOMAIN" 2>/dev/null \
            | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    if [ -z "$END" ]; then
        warn "取不到 $DOMAIN 的证书（Nginx 没起 / 443 不通？）"
    else
        END_TS=$(date -d "$END" +%s 2>/dev/null || echo 0)
        if [ "$END_TS" = "0" ]; then
            warn "证书到期时间无法解析：$END"
        else
            DAYS=$(( (END_TS - $(date +%s)) / 86400 ))
            if [ "$DAYS" -lt 0 ]; then
                fail "证书已过期 ${DAYS#-} 天：$DOMAIN"
            elif [ "$DAYS" -lt "$CERT_MIN_DAYS" ]; then
                warn "证书 ${DAYS} 天后到期（阈值 ${CERT_MIN_DAYS} 天），检查续期任务"
            else
                ok "证书剩余 ${DAYS} 天（$DOMAIN）"
            fi
        fi
    fi
fi

# ── 6. 慢查询日志体积（只告警，不计失败）────────────────────────────
# 慢查询是常开的（compose 里 --slow-query-log=1，阈值 2 秒），为的是出事时有据可查：
# 指标只能告诉你 p99 变慢，定位不到是哪条 SQL。
# 但没人看着它就会默默涨大——这条只负责「超过阈值提醒」，不自动删日志：
# 看到告警的正确反应是去看 SQL，而不是把证据删掉。
SLOW_LOG_MAX_MB=${SLOW_LOG_MAX_MB:-50}
if ! command -v docker >/dev/null 2>&1; then
    skip "慢查询日志（没有 docker）"
else
    # 用 `cat | wc -c` 数字节：du 对小文件会按块取整（362 字节也会显示 1MB），
    # 报出来的数字看着像"有慢查询"，其实只是文件系统块大小。
    SLOW_BYTES=$(docker exec otaku-mysql sh -c \
        'cat /var/lib/mysql/*-slow.log 2>/dev/null | wc -c' 2>/dev/null | tr -d '\r')
    if [ -z "${SLOW_BYTES:-}" ]; then
        skip "慢查询日志（取不到大小，可能容器名不同或未开启）"
    else
        SLOW_MB=$(( SLOW_BYTES / 1048576 ))
        if [ "$SLOW_MB" -gt "$SLOW_LOG_MAX_MB" ]; then
            warn "慢查询日志 ${SLOW_MB}MB（阈值 ${SLOW_LOG_MAX_MB}MB）——有查询超过 2 秒，去看 SQL"
        else
            ok "慢查询日志 ${SLOW_MB}MB（${SLOW_BYTES} 字节）"
        fi
    fi
fi

# ── 7. 内存与 swap（只告警，不计失败）────────────────────────────────
# 2G 机器上同时跑 mysql(570M) + java(210M) + 别的项目(240M)，内存是这台机器最先见的底。
# 判据用「可用内存」而不是「swap 用了多少」：swap 有几百兆是常态（内核会把冷页换出去），
# 真正危险的是 available 见底——那时候 OOM killer 随时会挑一个进程开刀。
MEM_AVAIL_MB=$(free -m | awk '/^Mem:/{print $7}')
SWAP_USED_MB=$(free -m | awk '/^Swap:/{print $3}')
SWAP_TOTAL_MB=$(free -m | awk '/^Swap:/{print $2}')
if [ -z "${MEM_AVAIL_MB:-}" ]; then
    skip "内存（读不到 free 输出）"
elif [ "$MEM_AVAIL_MB" -lt "${MEM_MIN_AVAIL_MB:-200}" ]; then
    warn "可用内存仅 ${MEM_AVAIL_MB}MB（阈值 ${MEM_MIN_AVAIL_MB:-200}MB），swap 已用 ${SWAP_USED_MB:-0}MB"
else
    ok "可用内存 ${MEM_AVAIL_MB}MB，swap ${SWAP_USED_MB:-0}/${SWAP_TOTAL_MB:-0}MB"
fi

# 告警通道本身也要能被看见：没配就每轮 SKIP 一行，别等出事才发现"没人收得到"
if [ -n "$ALERT_WEBHOOK" ]; then
    ok "告警通道已配置（webhook）"
else
    skip "告警通道未配置（.env 的 ALERT_WEBHOOK）：失败只进 syslog，没有人会收到通知"
fi

if [ "$FAILS" -gt 0 ]; then
    printf '巡检失败：%d 项\n' "$FAILS" >&2
    notify "巡检失败 ${FAILS} 项 @ $(hostname)（站点 ${SITE_KEY}）：${FAIL_LINES}"
    exit 1
fi
say "巡检通过：全部正常（站点 ${SITE_KEY}）"

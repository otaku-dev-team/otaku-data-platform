#!/usr/bin/env bash
#
# 每日数据库备份。给 cron / systemd timer 调，也可以手动跑。
#
#   ./deploy/backup.sh              # 正常备份
#   ./deploy/backup.sh --dry-run    # 只打印要做什么，不执行（本地自测用）
#
# 设计上刻意做的几件事：
#
#   1. **口令不出容器**：mysqldump 在 mysql 容器里跑，密码从容器自己的
#      $MYSQL_ROOT_PASSWORD 读。宿主机上不需要、也不应该再存一份。
#   2. **流式 gzip**：不落中间文件。2G 内存的机器上，先 dump 到磁盘再压
#      会让磁盘和内存峰值叠加。
#   3. **先写 .part 再 mv**：备份进程被 kill（OOM、重启）时，不会留下一个
#      看起来正常、实际截断的 .sql.gz —— 那种文件比没有备份更危险。
#   4. **写完就验**：gzip -t 过一遍，且大小必须超过下限。损坏的备份等于没备份。
#   5. **flock**：cron 和手动同时跑时，后到的直接退出，不产生两份半成品。
#
# 退出码：0 成功；1 失败（cron 会因此发邮件 / 被监控抓到）。

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(dirname "$SCRIPT_DIR")
COMPOSE_FILE=${COMPOSE_FILE:-$ROOT_DIR/compose.prod.yaml}

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# ── 从 .env 读少量配置（不 source：.env 里有空格和特殊字符，source 会执行它）──
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
BACKUP_DIR=${BACKUP_DIR:-$(read_env BACKUP_DIR /var/backups/otaku)}
RETAIN_DAYS=${RETAIN_DAYS:-$(read_env BACKUP_RETAIN_DAYS 14)}
MIN_FREE_MB=${MIN_FREE_MB:-$(read_env MIN_FREE_MB 2048)}
# 大小下限：默认 1 MB，是按「全量几十万行」估的。
# 库还没导数据时（刚部署、空库跑通链路）会因此判失败——这是**故意的**，
# 它挡的正是「mysqldump 连不上、写了个几 KB 的空文件却报成功」。
# 确实要在空库上验收备份链路，就在 .env 里临时写 MIN_SIZE_KB=4，导完数据改回去。
MIN_SIZE_KB=${MIN_SIZE_KB:-$(read_env MIN_SIZE_KB 1024)}

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT="$BACKUP_DIR/${SITE_KEY}-${STAMP}.sql.gz"
PART="$OUT.part"
LOCK="$BACKUP_DIR/.backup.lock"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
die() { printf '[%s] 失败：%s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; exit 1; }

[ -f "$COMPOSE_FILE" ] || die "找不到 compose 文件：$COMPOSE_FILE"

if [ "$DRY_RUN" = "1" ]; then
    log "dry-run：将执行以下动作"
    log "  备份目录      $BACKUP_DIR"
    log "  输出文件      $OUT"
    log "  保留天数      $RETAIN_DAYS"
    log "  compose 文件  $COMPOSE_FILE"
    log "  dump 命令     docker compose -f ... exec -T mysql sh -c 'exec mysqldump ... \"\$MYSQL_DATABASE\"' | gzip"
    exit 0
fi

mkdir -p "$BACKUP_DIR"
[ -w "$BACKUP_DIR" ] || die "备份目录不可写：$BACKUP_DIR（cron 下常见于目录属主不对）"

# ── 前置检查：compose 能不能解析 ─────────────────────────────────────
# 不先查的话，.env 少一个必填项会在 mysqldump 那一步炸，报错变成
# 「dump 失败」——指向完全错误的方向（实际是配置问题，压根没连上库）。
if ! docker compose -f "$COMPOSE_FILE" config --quiet >/dev/null; then
    die "compose 配置无法解析（上面是具体原因）。
先手动跑一次看：docker compose -f $COMPOSE_FILE config
最常见的是 .env 里 DOMAIN / DB_PASSWORD / OTAKU_INTERNAL_TOKEN 没填。"
fi

# ── 单实例：拿不到锁说明上一轮还在跑，直接退出（不算失败）────────────
# 注意区分两件事：
#   - 锁被别的进程占着 → 正常跳过（exit 0）
#   - 机器上根本没有 flock → **不能**当成"已有备份在跑"，否则备份会永远不执行
#     而退出码还是 0。这里降级为「不做单实例保护，但继续备份」并显式告警。
if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK"
    if ! flock -n 9; then
        log "已有备份在跑（锁被占用），本次跳过"
        exit 0
    fi
else
    printf '[%s] 警告：系统没有 flock（util-linux），跳过单实例保护；' "$(date -u +%H:%M:%SZ)" >&2
    printf '如果 cron 与手动备份同时触发，可能产生两份备份。\n' >&2
fi

# ── 磁盘预检：不够就先失败，别把磁盘写满导致 MySQL 也起不来 ─────────
FREE_MB=$(df -Pk "$BACKUP_DIR" | awk 'NR==2 {print int($4/1024)}')
if [ -z "$FREE_MB" ] || [ "$FREE_MB" -lt "$MIN_FREE_MB" ]; then
    die "磁盘可用空间不足：${FREE_MB:-未知} MB < ${MIN_FREE_MB} MB"
fi

trap 'rm -f "$PART"' EXIT

log "开始备份 → $OUT"
START=$(date +%s)

# 管道里三个进程：compose exec / gzip / 重定向。
# pipefail 是这里唯一能保证「mysqldump 报错不会被 gzip 的成功掩盖」的东西。
if ! docker compose -f "$COMPOSE_FILE" exec -T mysql sh -c \
        'exec mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" \
            --single-transaction \
            --quick \
            --set-gtid-purged=OFF \
            --default-character-set=utf8mb4 \
            "$MYSQL_DATABASE"' \
        | gzip -6 > "$PART"; then
    die "mysqldump 或 gzip 失败（.part 已清理）"
fi

# ── 校验：截断的备份比没有备份更危险，所以宁可这次失败 ──────────────
gzip -t "$PART" 2>/dev/null || die "gzip 完整性校验失败"

SIZE_KB=$(du -k "$PART" | cut -f1)
[ "$SIZE_KB" -ge "$MIN_SIZE_KB" ] || die "备份只有 ${SIZE_KB} KB，低于下限 ${MIN_SIZE_KB} KB（库是空的？连接错了？）"

mv "$PART" "$OUT"
trap - EXIT

log "完成：$(basename "$OUT") ${SIZE_KB} KB，耗时 $(( $(date +%s) - START ))s"

# ── 保留期：只删本前缀的 .sql.gz，别碰同目录里别的文件 ──────────────
DELETED=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name "${SITE_KEY}-*.sql.gz" \
            -mtime +"$RETAIN_DAYS" -print -delete | wc -l | tr -d ' ')
[ "$DELETED" != "0" ] && log "清理过期备份 ${DELETED} 个（> ${RETAIN_DAYS} 天）"

log "当前备份：$(find "$BACKUP_DIR" -maxdepth 1 -type f -name "${SITE_KEY}-*.sql.gz" | wc -l | tr -d ' ') 个"

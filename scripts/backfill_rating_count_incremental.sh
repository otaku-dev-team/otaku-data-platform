#!/bin/bash
# 评分人数增量回填（cron 用）：只处理 id 大于游标的行。
#
# 为什么不是每天全量：库里还有 8,840 行是镜像**永久 404** 的未收录存量，
# 全量跑每次都要把这两千多条重打一遍（每次约 10 分钟）；而新导入的作品 id 一定更大，
# 用游标就只需要看「上次之后新增的行」，正常情况下一条查询就退出。
#
# 游标：/opt/otaku/data/rating-backfill.cursor（首次手工写成已处理到的最大 id）
# 日志：/opt/otaku/data/rating-backfill.log
# 停：cron 里删掉那一行即可，脚本本身没有常驻进程。
set -u
cd /opt/otaku/backend || exit 1
set -a; . ./.env; set +a
export OTAKU_DB_USER="$DB_USER" OTAKU_DB_PASSWORD="$DB_PASSWORD" \
       OTAKU_DB_NAME="$DB_NAME" MYSQL_CONTAINER=otaku-mysql

CURSOR_FILE=/opt/otaku/data/rating-backfill.cursor
LOG=/opt/otaku/data/rating-backfill.log
CURSOR=$(cat "$CURSOR_FILE" 2>/dev/null || echo 0)

OUT=$(/opt/otaku/sync-venv/bin/python /opt/otaku/data/backfill_rating_count.py \
        --apply docker --limit 4000 --concurrency 6 --after-id "$CURSOR" 2>&1)

{
  echo "===== $(date '+%F %T') cursor=$CURSOR"
  echo "$OUT" | tail -3
} >> "$LOG"

NEXT=$(echo "$OUT" | sed -n 's/.*next --after-id=\([0-9][0-9]*\).*/\1/p' | tail -1)
if [ -n "$NEXT" ] && [ "$NEXT" -gt "$CURSOR" ]; then
  echo "$NEXT" > "$CURSOR_FILE.tmp" && mv "$CURSOR_FILE.tmp" "$CURSOR_FILE"
  echo "[cron] cursor -> $NEXT" >> "$LOG"
else
  echo "[cron] 没有新行要补（fetched 0）" >> "$LOG"
fi

# 失败要能被 cron 看见：这是 #394 教过的事——静默失败比报错难查得多。
# 脚本内部对 mysql 抖动会打 FETCH_ERROR 并以 2 退出，这里把它透传出去，
# 免得「一条都没补」和「根本没连上」在日志里长得一样。
if echo "$OUT" | grep -q 'FETCH_ERROR'; then
  echo "[cron] FETCH_ERROR，本轮失败，游标不动" >> "$LOG"
  exit 2
fi
exit 0

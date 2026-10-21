#!/usr/bin/env bash
#
# 导出数据库，用于迁移到服务器。可选「导出后立刻验证能恢复」。
#
# 为什么要有这个脚本：手工拼 mysqldump 参数容易漏，而漏掉的参数不会报错，
# 只会在恢复的时候才暴露（中文变问号、GTID 报错、dump 被截断）。
# 这个脚本把参数固定下来，并做真正的一致性校验。
#
# 用法：
#   # 本机（MySQL 在 3310，客户端在 /d/mysql/bin）
#   MYSQL=/d/mysql/bin/mysql.exe MYSQLDUMP=/d/mysql/bin/mysqldump.exe \
#     DB_PORT=3310 DB_USER=root DB_PASSWORD= \
#     ./scripts/dump-db.sh --out /d/otaku-migration/otaku-full.sql --verify
#
#   # 服务器上（mysql 已在 PATH）
#   DB_USER=root DB_PASSWORD='...' ./scripts/dump-db.sh --out /var/backups/otaku.sql
#
# 校验口径：不只比行数，还比「逐行内容指纹」（SUM(CRC32(...))）。
# 行数相同但内容被截断/替换的情况，只有指纹能发现。

set -euo pipefail

DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"
DB_USER="${DB_USER:-root}"
DB_PASSWORD="${DB_PASSWORD:-}"
DB_NAME="${DB_NAME:-otaku}"

MYSQL="${MYSQL:-mysql}"
MYSQLDUMP="${MYSQLDUMP:-mysqldump}"

OUT=""
VERIFY=0

usage() {
  cat <<'EOF'
用法: dump-db.sh --out <文件路径> [--verify]

  --out <路径>   导出到哪个文件（默认 otaku-<时间戳>.sql）
  --verify       导出后建临时库导入一遍，比对行数与内容指纹，然后删掉临时库
  -h, --help     显示本帮助

环境变量: DB_HOST DB_PORT DB_USER DB_PASSWORD DB_NAME MYSQL MYSQLDUMP
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="${2:?--out 需要一个路径}"; shift 2 ;;
    --verify) VERIFY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "$OUT" ]] || OUT="otaku-$(date +%Y%m%d-%H%M).sql"
export MYSQL_PWD="$DB_PASSWORD"

mysql_run() {
  "$MYSQL" -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" --default-character-set=utf8mb4 "$@"
}

echo "==> 导出 $DB_NAME @ $DB_HOST:$DB_PORT → $OUT"
"$MYSQLDUMP" -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" \
  --single-transaction \
  --set-gtid-purged=OFF \
  --default-character-set=utf8mb4 \
  --result-file="$OUT" \
  "$DB_NAME"

# 最低限度的完整性证据：正常结束的 dump 最后会有这一行。
# 中途被杀、磁盘满，都会让文件看起来「有内容」但没有这行。
if ! tail -5 "$OUT" | grep -q "Dump completed"; then
  echo "!! 失败：dump 末尾没有 'Dump completed'，导出不完整，不要拿去用" >&2
  exit 1
fi

echo "==> 完成"
echo "    大小   : $(wc -c < "$OUT") 字节"
echo "    表数量 : $(grep -c '^CREATE TABLE' "$OUT" || true)"
if command -v sha256sum >/dev/null 2>&1; then
  echo "    SHA256 : $(sha256sum "$OUT" | cut -d' ' -f1)"
elif command -v shasum >/dev/null 2>&1; then
  echo "    SHA256 : $(shasum -a 256 "$OUT" | cut -d' ' -f1)"
fi

if [[ "$VERIFY" -ne 1 ]]; then
  echo
  echo "提示：加 --verify 可以立刻验证这份 dump 能不能恢复。"
  exit 0
fi

# ── 验证：导入临时库，比对行数与内容指纹 ──────────────────────
CHECK_DB="${DB_NAME}_migrate_check"

cleanup() {
  echo "==> 删除临时库 $CHECK_DB"
  mysql_run -e "DROP DATABASE IF EXISTS \`$CHECK_DB\`;" || true
}
trap cleanup EXIT

echo
echo "==> 建临时库 $CHECK_DB"
mysql_run -e "DROP DATABASE IF EXISTS \`$CHECK_DB\`;
              CREATE DATABASE \`$CHECK_DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;"

echo "==> 导入（这一步验证的正是「服务器上会发生什么」）"
mysql_run "$CHECK_DB" < "$OUT"

# 两边的表都可能不全（早期库没有 collection），所以查之前先确认表在不在。
table_exists() {
  local n
  n=$(mysql_run -N -e "SELECT COUNT(*) FROM information_schema.tables
                        WHERE table_schema='$1' AND table_name='$2';")
  [[ "$n" == "1" ]]
}

echo
echo "==> 比对结果"
FAILED=0

compare_table() {
  local table="$1" expr="$2"
  if ! table_exists "$DB_NAME" "$table" || ! table_exists "$CHECK_DB" "$table"; then
    echo "    $table：跳过（表不存在）"
    return
  fi

  local orig rest

  # 关键：命令失败或取到空值都必须判失败。
  # 这里踩过一次真实的坑——表达式里写了不存在的列（display_name），两边都返回空字符串，
  # 直接比较就成了「一致」，把一个真正的错误报成通过。
  if ! orig=$(mysql_run -N -e "SELECT CONCAT(COUNT(*), ':', COALESCE(SUM(CRC32($expr)),0)) FROM \`$DB_NAME\`.\`$table\`;" 2>&1); then
    orig=$(echo "$orig" | tr -d '\r')
    echo "    $table：查询失败，无法比对 → $orig"
    FAILED=1
    return
  fi
  if ! rest=$(mysql_run -N -e "SELECT CONCAT(COUNT(*), ':', COALESCE(SUM(CRC32($expr)),0)) FROM \`$CHECK_DB\`.\`$table\`;" 2>&1); then
    rest=$(echo "$rest" | tr -d '\r')
    echo "    $table：查询失败，无法比对 → $rest"
    FAILED=1
    return
  fi

  orig=$(echo "$orig" | tr -d '\r\n')
  rest=$(echo "$rest" | tr -d '\r\n')

  if [[ -z "$orig" || -z "$rest" ]]; then
    echo "    $table：取到空值，无法确认一致（原库='$orig' 恢复库='$rest'）"
    FAILED=1
    return
  fi

  if [[ "$orig" == "$rest" ]]; then
    echo "    $table：一致（行数:指纹 = $orig）"
  else
    echo "    $table：不一致！原库=$orig 恢复库=$rest"
    FAILED=1
  fi
}

compare_table work        "CONCAT_WS('|', work_id, title, COALESCE(summary,''), COALESCE(release_year,0), COALESCE(source_url,''), source, source_id, COALESCE(rating_value,0))"
compare_table collection  "CONCAT_WS('|', user_id, work_id, status, updated_at)"
compare_table app_user    "CONCAT_WS('|', user_id, username, password_hash, updated_at)"
compare_table import_batch        "CONCAT_WS('|', batch_id, source, inserted, updated, unchanged, rejected)"
compare_table import_batch_run    "CONCAT_WS('|', batch_id, run_seq, inserted, updated, unchanged, rejected)"

# 中文抽查：编码错了会变成问号，而问号在数据里本来就存在，所以看「问号占比是否暴涨」。
if table_exists "$DB_NAME" work; then
  local_q=$(mysql_run -N -e "SELECT COUNT(*) FROM \`$CHECK_DB\`.work WHERE title LIKE '%?%';" | tr -d '\r')
  orig_q=$(mysql_run -N -e "SELECT COUNT(*) FROM \`$DB_NAME\`.work WHERE title LIKE '%?%';" | tr -d '\r')
  if [[ "$local_q" == "$orig_q" ]]; then
    echo "    work.title 问号数：一致（$orig_q 条，原本就带问号的标题）"
  else
    echo "    work.title 问号数：不一致！原库=$orig_q 恢复库=$local_q（很可能是编码问题）"
    FAILED=1
  fi
fi

echo
if [[ "$FAILED" -eq 0 ]]; then
  echo "==> 校验通过：这份 dump 可以在服务器上恢复出与原库一致的数据"
else
  echo "!! 校验失败：不要拿这份 dump 去迁移" >&2
  exit 1
fi

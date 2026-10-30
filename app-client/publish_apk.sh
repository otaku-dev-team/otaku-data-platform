#!/usr/bin/env bash
# 发布 APK 到下载站 —— 上传、改写清单、清理旧包，一条命令做完。
#
# 为什么要有这个脚本：手工 scp 之后最容易漏的是「旧包越堆越多」和
# 「latest.json 改了但 APK 没传上去」。前者吃满磁盘，后者让所有客户端
# 下载到 404。这里把顺序固定成：
#
#   传 APK（先写 .part 再 mv，避免半截文件对外可见）
#     → 写 latest.json（同样先 .part 再 mv，清单永不出现半截 JSON）
#     → 清理：只保留当前包 + N 个历史包
#
# 清理**永远不会删 latest.json 指向的那个文件**，哪怕它时间很旧（回滚后
# 就是这种情况）。删之前会把要删的清单打出来。
#
# 用法：
#   ./publish_apk.sh --apk build/app/outputs/flutter-apk/app-release.apk \
#     --version-name 1.1.2 --version-code 4 \
#     --changelog "安装包从 170MB 降到 20MB" --changelog "登录不再转圈"
#
# 联调机（默认目标）：
#   HOST=riceyu02@154.8.194.198  KEY=~/.ssh/otaku_deploy
#   REMOTE_DIR=/opt/otaku/downloads  BASE_URL=http://154.8.194.198/downloads
#
# 常用选项：
#   --keep <n>       保留几个包（含当前，默认 2 = 当前 + 上一个，供回滚）
#   --prune-only     只清理，不上传不写清单
#   --dry-run        只打印将要做的事
#   --force          远端已有同名文件且 sha256 相同时也重传

set -euo pipefail
cd "$(dirname "$0")"

APK=""
VERSION_NAME=""
VERSION_CODE=""
CHANGELOG=()
KEEP=2
DRY_RUN=0
PRUNE_ONLY=0
FORCE=0
HOST="${HOST:-riceyu02@154.8.194.198}"
KEY="${KEY:-$HOME/.ssh/otaku_deploy}"
REMOTE_DIR="${REMOTE_DIR:-/opt/otaku/downloads}"
BASE_URL="${BASE_URL:-http://154.8.194.198/downloads}"
MIN_SUPPORTED="1"

say() { printf '[publish] %s\n' "$*"; }
die() {
  printf '[publish] 失败：%s\n' "$*" >&2
  exit 1
}

usage() {
  sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apk) APK="${2:-}"; shift 2 ;;
    --apk=*) APK="${1#*=}"; shift ;;
    --version-name) VERSION_NAME="${2:-}"; shift 2 ;;
    --version-name=*) VERSION_NAME="${1#*=}"; shift ;;
    --version-code) VERSION_CODE="${2:-}"; shift 2 ;;
    --version-code=*) VERSION_CODE="${1#*=}"; shift ;;
    --changelog) CHANGELOG+=("${2:-}"); shift 2 ;;
    --changelog=*) CHANGELOG+=("${1#*=}"); shift ;;
    --keep) KEEP="${2:-}"; shift 2 ;;
    --keep=*) KEEP="${1#*=}"; shift ;;
    --min-supported) MIN_SUPPORTED="${2:-}"; shift 2 ;;
    --host) HOST="${2:-}"; shift 2 ;;
    --key) KEY="${2:-}"; shift 2 ;;
    --remote-dir) REMOTE_DIR="${2:-}"; shift 2 ;;
    --base-url) BASE_URL="${2:-}"; shift 2 ;;
    --prune-only) PRUNE_ONLY=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --force) FORCE=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) die "不认识的参数：$1（--help 看用法）" ;;
  esac
done

case "$KEEP" in
  '' | *[!0-9]*) die "--keep 要是正整数，当前：$KEEP" ;;
esac
[ "$KEEP" -ge 1 ] || die "--keep 至少为 1（1 = 只留当前包）"

ssh_opts=(-i "$KEY" -o BatchMode=yes -o ConnectTimeout=10)
remote() { ssh "${ssh_opts[@]}" "$HOST" "$@"; }
[ -f "$KEY" ] || die "找不到 SSH 私钥：$KEY（用 --key 指定）"

if [ "$PRUNE_ONLY" -eq 0 ]; then
  [ -n "$APK" ] || die "缺少 --apk"
  [ -f "$APK" ] || die "找不到 APK：$APK"
  [[ "$VERSION_NAME" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] ||
    die "--version-name 要形如 1.2.3，当前：$VERSION_NAME"
  [[ "$VERSION_CODE" =~ ^[0-9]+$ ]] || die "--version-code 要整数，当前：$VERSION_CODE"
fi

APK_NAME="otaku-${VERSION_NAME}.apk"
REMOTE_APK="$REMOTE_DIR/$APK_NAME"

# ── 1. 上传 APK ───────────────────────────────────────────────
if [ "$PRUNE_ONLY" -eq 0 ]; then
  LOCAL_SHA=$(sha256sum "$APK" | cut -d' ' -f1)
  LOCAL_SIZE=$(wc -c <"$APK" | tr -d ' ')
  say "包：$APK_NAME（$(du -h "$APK" | cut -f1)，sha256 ${LOCAL_SHA:0:12}…）"

  REMOTE_SHA=$(remote "sha256sum '$REMOTE_APK' 2>/dev/null | cut -d' ' -f1" || true)
  if [ "$FORCE" -eq 0 ] && [ -n "$REMOTE_SHA" ] && [ "$REMOTE_SHA" = "$LOCAL_SHA" ]; then
    say "远端已有同名同哈希文件，跳过上传"
  else
    if [ "$DRY_RUN" -eq 1 ]; then
      say "[dry-run] 会上传 $APK → $HOST:$REMOTE_APK"
    else
      # 先传临时名再 mv：下载者永远看不到传了一半的 APK。
      scp -i "$KEY" -o BatchMode=yes "$APK" "$HOST:$REMOTE_APK.part"
      remote "mv -f '$REMOTE_APK.part' '$REMOTE_APK' && sha256sum '$REMOTE_APK'"
      GOT=$(remote "sha256sum '$REMOTE_APK' | cut -d' ' -f1")
      [ "$GOT" = "$LOCAL_SHA" ] || die "上传后哈希不一致（远端 $GOT）"
      say "上传完成，哈希校验通过"
    fi
  fi

  # ── 2. 写清单 ───────────────────────────────────────────────
  # 手拼 JSON 而不是引 python：这个脚本要在只有 git-bash 的 Windows 上也能跑。
  # 只转义 \ 和 "，其余（中文、斜杠）按 UTF-8 原样写。
  json_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

  # 用相对路径的临时文件，不用 mktemp：Windows 上 mktemp 返回带盘符的
  # `C:\...` 路径，某些环境下 rm 会拒绝删它，留下垃圾。
  TMP_JSON="./.latest.json.tmp"
  trap 'rm -f "$TMP_JSON"' EXIT
  {
    printf '{\n'
    printf '  "versionCode": %s,\n' "$VERSION_CODE"
    printf '  "versionName": "%s",\n' "$(json_esc "$VERSION_NAME")"
    printf '  "downloadUrl": "%s/%s",\n' "${BASE_URL%/}" "$APK_NAME"
    printf '  "sha256": "%s",\n' "$LOCAL_SHA"
    printf '  "sizeBytes": %s,\n' "$LOCAL_SIZE"
    if [ ${#CHANGELOG[@]} -gt 0 ]; then
      printf '  "changelog": [\n'
      last=$((${#CHANGELOG[@]} - 1))
      for i in "${!CHANGELOG[@]}"; do
        sep=","
        [ "$i" -eq "$last" ] && sep=""
        printf '    "%s"%s\n' "$(json_esc "${CHANGELOG[$i]}")" "$sep"
      done
      printf '  ],\n'
    fi
    printf '  "minSupportedVersionCode": %s\n' "$MIN_SUPPORTED"
    printf '}\n'
  } >"$TMP_JSON"

  if [ "$DRY_RUN" -eq 1 ]; then
    say "[dry-run] 清单内容："
    sed 's/^/    /' "$TMP_JSON"
  else
    scp -i "$KEY" -o BatchMode=yes "$TMP_JSON" "$HOST:$REMOTE_DIR/latest.json.part"
    remote "mv -f '$REMOTE_DIR/latest.json.part' '$REMOTE_DIR/latest.json'"
    say "清单已切到 $VERSION_NAME（versionCode $VERSION_CODE）"
  fi
fi

# ── 3. 清理旧包 ───────────────────────────────────────────────
# 规则：latest.json 指向的文件强制保留；其余按修改时间从新到旧，
# 只留 KEEP-1 个。这样「回滚后把清单指回旧包」也不会把旧包删掉。
if [ "$DRY_RUN" -eq 1 ]; then
  remote "cd '$REMOTE_DIR' && ls -1t *.apk 2>/dev/null | head -20" |
    sed 's/^/[publish] 现有包：/'
  say "[dry-run] 会保留最新 $KEEP 个（含 latest.json 指向的），其余删除"
  exit 0
fi

say "清理策略：保留 $KEEP 个（含清单指向的），其余删除"
remote "cd '$REMOTE_DIR' && KEEP='$KEEP' bash -s" <<'REMOTE_EOF'
set -u
CUR=$(sed -n 's/.*"downloadUrl"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' latest.json 2>/dev/null | sed 's#.*/##')
[ -n "${CUR:-}" ] || { echo "[publish] 警告：读不到 latest.json 的 downloadUrl，保守起见不删任何包"; exit 0; }
[ -f "$CUR" ] || echo "[publish] 警告：清单指向 $CUR，但文件不存在"

kept=0
deleted=0
freed=0
# ls -1t：按修改时间从新到旧
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if [ "$f" = "$CUR" ]; then
    echo "[publish] 保留 $f（清单指向）"
    continue
  fi
  if [ "$kept" -lt "$((KEEP - 1))" ]; then
    echo "[publish] 保留 $f（历史版本）"
    kept=$((kept + 1))
  else
    sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
    rm -f "$f"
    echo "[publish] 删除 $f（$((sz / 1024 / 1024))MB）"
    deleted=$((deleted + 1))
    freed=$((freed + sz))
  fi
done < <(ls -1t *.apk 2>/dev/null)
echo "[publish] 清理完成：删除 $deleted 个，释放 $((freed / 1024 / 1024))MB"
REMOTE_EOF

say "当前目录："
remote "cd '$REMOTE_DIR' && ls -lh *.apk latest.json 2>/dev/null | awk '{print \"    \" \$5 \"\t\" \$9}'"

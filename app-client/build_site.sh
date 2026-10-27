#!/usr/bin/env bash
# 按站烘焙客户端 —— 一条命令出这个站的包。
#
# 用法：
#   ./build_site.sh --site otaku                     # Windows release
#   ./build_site.sh --site otaku --build-mode debug   # 联调用的 debug 包
#   ./build_site.sh --site otaku --target apk --build-mode debug
#   ./build_site.sh --site otaku --dry-run            # 只打印命令，不构建
#   ./build_site.sh --list                            # 列出已有站点
#
# 为什么要有这个脚本：换一个站要同时改 5 个值（APP_NAME / SITE_ID / BRAND_COMPANY /
# APP_ID / API_BASE_URL），手敲时漏一个不会报错，只会静默出错——漏 API_BASE_URL
# 是「装得上但连错站」，漏 APP_ID 是两个站同机互相覆盖。值集中在
# sites/<site>/site.conf，注入交给脚本。
#
# 边界（与 docs/site-branding.md §3 一致）：图标与 Windows 包标识仍需人工替换，
# 脚本跑完会把它们打印成待办。Android 的 -P 透传本轮未实测（先不动安卓），
# 首次真机构建时确认一次即可。

set -euo pipefail

cd "$(dirname "$0")"

SITE=""
TARGET="windows"
MODE="release"
DRY_RUN=0

say() { printf '[build_site] %s\n' "$*"; }
die() {
  printf '[build_site] 失败：%s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
按站烘焙客户端 —— 一条命令出这个站的包。

用法：
  ./build_site.sh --site <站点键> [选项]

选项：
  --site <键>          必填。sites/<键>/site.conf 里的站点
  --target <平台>      windows（默认）| apk
  --build-mode <模式>  debug | profile | release（默认）
  --dry-run            只打印将要执行的命令，不构建
  --list               列出已有站点
  -h, --help           显示本帮助

例子：
  ./build_site.sh --site otaku
  ./build_site.sh --site otaku --build-mode debug
  ./build_site.sh --site otaku --target apk --build-mode debug
EOF
}

list_sites() {
  if [ ! -d sites ]; then
    say "sites/ 目录不存在"
    return 0
  fi
  local found=0
  for dir in sites/*/; do
    [ -f "${dir}site.conf" ] || continue
    found=1
    printf '  %s\n' "$(basename "$dir")"
  done
  [ "$found" -eq 1 ] || say "sites/ 下没有站点（缺 site.conf）"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --site) SITE="${2:-}"; shift 2 ;;
    --site=*) SITE="${1#*=}"; shift ;;
    --target) TARGET="${2:-}"; shift 2 ;;
    --target=*) TARGET="${1#*=}"; shift ;;
    --build-mode) MODE="${2:-}"; shift 2 ;;
    --build-mode=*) MODE="${1#*=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --list) say "已有站点："; list_sites; exit 0 ;;
    -h | --help) usage; exit 0 ;;
    *) die "不认识的参数：$1（--help 看用法）" ;;
  esac
done

[ -n "$SITE" ] || die "缺少 --site（--list 看有哪些站）"
case "$TARGET" in
  windows | apk) ;;
  *) die "--target 只支持 windows / apk，当前：$TARGET" ;;
esac
case "$MODE" in
  debug | profile | release) ;;
  *) die "--build-mode 只支持 debug / profile / release，当前：$MODE" ;;
esac

CONF="sites/$SITE/site.conf"
[ -f "$CONF" ] || {
  say "找不到 $CONF"
  list_sites
  exit 1
}

# 读 KEY="值"。两种写法都认：带引号（允许空格与中文）与裸值。
conf_get() {
  local key="$1" value
  value=$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"\(.*\)\"[[:space:]]*$/\1/p" "$CONF" | tail -n 1)
  if [ -z "$value" ]; then
    value=$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\([^\"]*\)[[:space:]]*$/\1/p" "$CONF" | tail -n 1)
  fi
  printf '%s' "$value"
}

for key in SITE_ID APP_NAME BRAND_COMPANY APP_ID API_BASE_URL; do
  [ -n "$(conf_get "$key")" ] || die "$CONF 缺少 $key（或值为空）"
done

SITE_ID=$(conf_get SITE_ID)
APP_NAME=$(conf_get APP_NAME)
BRAND_COMPANY=$(conf_get BRAND_COMPANY)
APP_ID=$(conf_get APP_ID)
API_BASE_URL=$(conf_get API_BASE_URL)

case "$API_BASE_URL" in
  http://* | https://*) ;;
  *) die "API_BASE_URL 要以 http:// 或 https:// 开头，当前：$API_BASE_URL" ;;
esac
if [ "$TARGET" = "apk" ] && [ "$MODE" = "release" ]; then
  case "$API_BASE_URL" in
    http://*)
      say "注意：release 包连的是明文 HTTP，Android 会拒绝（release 只认 HTTPS）"
      say "      联调请用 --build-mode debug，或等域名到位换成 https://"
      ;;
  esac
fi

cmd=(flutter build "$TARGET" "--$MODE")
cmd+=("--dart-define=APP_NAME=$APP_NAME")
cmd+=("--dart-define=SITE_ID=$SITE_ID")
cmd+=("--dart-define=BRAND_COMPANY=$BRAND_COMPANY")
cmd+=("--dart-define=API_BASE_URL=$API_BASE_URL")
if [ "$TARGET" = "apk" ]; then
  # Android 的系统级身份只能构建期定（applicationId 与 Launcher 名），见 site-branding.md §0。
  cmd+=("-PappName=$APP_NAME" "-PappId=$APP_ID")
fi

say "站点：$SITE（$SITE_ID）"
printf '[build_site] 应用名：%s ｜ 归属：%s ｜ 包名：%s\n' "$APP_NAME" "$BRAND_COMPANY" "$APP_ID"
printf '[build_site] 后端：%s\n' "$API_BASE_URL"
printf '[build_site] 命令：'
printf ' %q' "${cmd[@]}"
printf '\n'

if [ "$DRY_RUN" -eq 1 ]; then
  say "--dry-run：没有构建"
  exit 0
fi

"${cmd[@]}"

# ── 产物与品牌自检 ────────────────────────────────────────────
# 「构建成功但品牌没进包」是最坏的失败：包能用，名字却是首站的。
# 这里只在字符串缺失时**警告**，不判失败——AOT 产物可能对字符串做了优化，
# 拿它当硬门槛会造出假红。
case "$TARGET" in
  windows)
    cfg="Release"
    [ "$MODE" = "debug" ] && cfg="Debug"
    [ "$MODE" = "profile" ] && cfg="Profile"
    artifact=$(find build/windows -type f -path "*/runner/$cfg/*.exe" 2>/dev/null | head -n 1)
    ;;
  apk)
    artifact="build/app/outputs/flutter-apk/app-$MODE.apk"
    ;;
esac

[ -n "${artifact:-}" ] && [ -f "$artifact" ] || die "构建结束了但没找到产物（$TARGET/$MODE）"
printf '[build_site] 产物：%s（%s）\n' "$artifact" "$(du -h "$artifact" | cut -f1)"

data_dir="$(dirname "$artifact")/data"
hit=""
for probe in "$data_dir/flutter_assets/kernel_blob.bin" "$data_dir/app.so"; do
  if [ -f "$probe" ] && grep -qa -- "$APP_NAME" "$probe"; then
    hit="$probe"
    break
  fi
done
if [ -n "$hit" ]; then
  say "品牌自检：产物里找到了「$APP_NAME」（$(basename "$hit")）"
else
  say "品牌自检：产物里没找到「$APP_NAME」——不一定是错（AOT 可能优化掉），"
  say "          但首站交付前请人工开一次 App 确认应用名与窗口标题"
fi

say "还剩两件手工的（docs/site-branding.md §3）："
say "  - 图标：android/app/src/main/res/mipmap-*/ic_launcher.png 与 windows/runner/resources/app_icon.ico"
say "  - Windows 包标识：windows/runner/Runner.rc 的 CompanyName / ProductName / FileDescription"

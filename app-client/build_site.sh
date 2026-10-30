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
# 脚本跑完会把它们打印成待办。
#
# Android 的 -P 透传已于 2026-10-28 实测（`-PappId=com.otaku.smoke -PappName=OtakuSmoke`
# + `aapt dump badging` 核对：package 与 application-label 都按参数变了），
# 不再是「未验证」状态。

set -euo pipefail

cd "$(dirname "$0")"

SITE=""
TARGET="windows"
MODE="release"
DRY_RUN=0
# 默认出「真数据」包：注入 USE_MOCK=false。App 的默认值是 true（开发期走
# assets/mock 夹具），出包时不覆盖就会得到「装得上但全是假数据」的包——
# 真机走查会把它误当成后端数据。要 Mock 包显式加 --mock。
USE_MOCK=false
# 远程更新的版本号。缺省从 pubspec.yaml 的 `version: x.y.z+n` 取；
# 发版时必须显式递增 --version-code（Android 用 versionCode 判断新旧）。
VERSION_NAME=""
VERSION_CODE=""
# 更新清单 / 安装包基地址（可选）。生产与 API 同域时不用传；
# 联调环境 API 直连 8080、nginx 在 80，要显式传：
#   --update-base-url http://154.8.194.198/downloads
UPDATE_BASE_URL=""
# 目标 CPU 架构。默认 all（三套都装，体积最大）。国内真机分发包用 arm64：
# debug 的 170MB 里有一半是 armeabi-v7a + x86_64 的 libflutter.so。
ABI="all"

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
  --mock               出 Mock 数据版（默认注真实后端：USE_MOCK=false）
  --version-name <x.y.z>  版本名，给人看（默认取 pubspec.yaml）
  --version-code <n>      版本号，整数、每次发版递增（默认取 pubspec.yaml 的 +n）
  --update-base-url <url> 更新清单 / 安装包基地址（默认 <API_BASE_URL>/downloads）
  --abi <架构>         apk 目标架构：arm64（默认推荐，约省 2/3）| arm32 | x64 | all
                       只出 arm64 的包无法装到 32 位老机与 x86 模拟器上
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
    --mock) USE_MOCK=true; shift ;;
    --version-name) VERSION_NAME="${2:-}"; shift 2 ;;
    --version-name=*) VERSION_NAME="${1#*=}"; shift ;;
    --version-code) VERSION_CODE="${2:-}"; shift 2 ;;
    --version-code=*) VERSION_CODE="${1#*=}"; shift ;;
    --update-base-url) UPDATE_BASE_URL="${2:-}"; shift 2 ;;
    --update-base-url=*) UPDATE_BASE_URL="${1#*=}"; shift ;;
    --abi) ABI="${2:-}"; shift 2 ;;
    --abi=*) ABI="${1#*=}"; shift ;;
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

case "$ABI" in
  all) ABI_TARGETS="android-arm,android-arm64,android-x64" ;;
  arm64) ABI_TARGETS="android-arm64" ;;
  arm32 | arm) ABI_TARGETS="android-arm" ;;
  x64) ABI_TARGETS="android-x64" ;;
  *) die "--abi 只支持 arm64 / arm32 / x64 / all，当前：$ABI" ;;
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
# 可选：来源站地址（HTML 页面，给 App 内 WebView 登录 / 注册用）。
# 不填不报错，只是登录页不显示站点入口——与不注入时的默认行为一致。
SITE_BASE_URL=$(conf_get SITE_BASE_URL)

# ── 版本号 ────────────────────────────────────────────────────────────
# 默认从 pubspec.yaml 取 `version: x.y.z+n`；显式参数优先。发版必须递增
# --version-code，否则客户端无法判断「这是不是新包」。
PUB_VERSION=$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml | head -n 1)
if [ -z "$VERSION_NAME" ]; then
  VERSION_NAME="${PUB_VERSION%%+*}"
  [ -n "$VERSION_NAME" ] || die "读不到 pubspec.yaml 的 version，请用 --version-name 指定"
fi
if [ -z "$VERSION_CODE" ]; then
  case "$PUB_VERSION" in
    *+*) VERSION_CODE="${PUB_VERSION##*+}" ;;
    *) VERSION_CODE=1 ;;
  esac
fi
case "$VERSION_CODE" in
  '' | *[!0-9]*) die "--version-code 必须是正整数，当前：$VERSION_CODE" ;;
esac
[ "$VERSION_CODE" -ge 1 ] || die "--version-code 必须 ≥ 1"
if [ -n "$UPDATE_BASE_URL" ]; then
  case "$UPDATE_BASE_URL" in
    http://* | https://*) UPDATE_BASE_URL="${UPDATE_BASE_URL%/}" ;;
    *) die "--update-base-url 要以 http:// 或 https:// 开头，当前：$UPDATE_BASE_URL" ;;
  esac
fi

case "$API_BASE_URL" in
  http://* | https://*) ;;
  *) die "API_BASE_URL 要以 http:// 或 https:// 开头，当前：$API_BASE_URL" ;;
esac
if [ "$TARGET" = "apk" ] && [ "$MODE" = "release" ]; then
  case "$API_BASE_URL" in
    http://*)
      # Android 9+ 默认禁明文，但 res/xml/network_security_config.xml 已把
      # 联调机 IP 加进白名单，release 直连是通的。换成新域名时必须同步加白，
      # 否则症状是「装得上、页面全空」，很难往证书/配置上想。
      say "注意：release 连的是明文 HTTP，依赖 network_security_config.xml 的白名单"
      say "      当前白名单只放行 154.8.194.198；换域名要同步更新，或等 https 到位"
      ;;
  esac
fi

cmd=(flutter build "$TARGET" "--$MODE")
cmd+=("--dart-define=APP_NAME=$APP_NAME")
cmd+=("--dart-define=SITE_ID=$SITE_ID")
cmd+=("--dart-define=BRAND_COMPANY=$BRAND_COMPANY")
cmd+=("--dart-define=API_BASE_URL=$API_BASE_URL")
cmd+=("--dart-define=USE_MOCK=$USE_MOCK")
cmd+=("--dart-define=APP_VERSION_NAME=$VERSION_NAME")
cmd+=("--dart-define=APP_VERSION_CODE=$VERSION_CODE")
if [ -n "$UPDATE_BASE_URL" ]; then
  cmd+=("--dart-define=UPDATE_BASE_URL=$UPDATE_BASE_URL")
fi
if [ -n "$SITE_BASE_URL" ]; then
  case "$SITE_BASE_URL" in
    http://* | https://*) ;;
    *) die "SITE_BASE_URL 要以 http:// 或 https:// 开头，当前：$SITE_BASE_URL" ;;
  esac
  cmd+=("--dart-define=SITE_BASE_URL=$SITE_BASE_URL")
fi
if [ "$TARGET" = "apk" ]; then
  # Android 的系统级身份只能构建期定（applicationId 与 Launcher 名），见 site-branding.md §0。
  cmd+=("--build-name=$VERSION_NAME" "--build-number=$VERSION_CODE")
  cmd+=("-PappName=$APP_NAME" "-PappId=$APP_ID")
  # 不用 --split-per-abi：拆分包会把 versionCode 改成 1000*abi+code，
  # 与清单里的 versionCode 对不上，更新判断会错位。单架构整包体积已足够小。
  cmd+=("--target-platform=$ABI_TARGETS")
fi

say "站点：$SITE（$SITE_ID）"
printf '[build_site] 应用名：%s ｜ 归属：%s ｜ 包名：%s\n' "$APP_NAME" "$BRAND_COMPANY" "$APP_ID"
printf '[build_site] 后端：%s（USE_MOCK=%s）\n' "$API_BASE_URL" "$USE_MOCK"
printf '[build_site] 版本：%s（%s）｜ 更新基址：%s\n' \
  "$VERSION_NAME" "$VERSION_CODE" "${UPDATE_BASE_URL:-<API_BASE_URL>/downloads}"
if [ "$TARGET" = "apk" ]; then
  printf '[build_site] 架构：%s\n' "$ABI"
fi
if [ "$TARGET" = "apk" ] && [ "$MODE" != "release" ]; then
  # debug 包含 kernel_blob.bin（JIT 字节码）与三套架构引擎，实测 170MB。
  # 发出去的都是给人装的包，这里直接提示，别等到有人抱怨下载不动。
  say "提示：$MODE 包体积很大（实测 debug 170MB / release+arm64 20MB），分发给别人请用 --build-mode release --abi arm64"
fi
if [ -n "$SITE_BASE_URL" ]; then
  printf '[build_site] 站点：%s（App 内登录 / 注册）\n' "$SITE_BASE_URL"
else
  say "站点地址未配置（SITE_BASE_URL）——App 内登录入口将不显示"
fi
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

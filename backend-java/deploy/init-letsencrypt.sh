#!/usr/bin/env bash
#
# 首次申请 Let's Encrypt 证书。
#
#   ./deploy/init-letsencrypt.sh             # 正式申请
#   ./deploy/init-letsencrypt.sh --staging   # 走 staging 环境（推荐先跑这个）
#
# 为什么要这么绕——先放一张假证书：
#
#   Nginx 的 ssl_certificate 指向不存在的文件时**根本起不来**，
#   而申请证书又需要 Nginx 在 :80 上应答 ACME 验证。鸡生蛋问题。
#   标准解法是先塞一张自签证书让 Nginx 能启动，签完真证书再 reload 换掉。
#
# 为什么先跑 --staging：
#   Let's Encrypt 对同一域名有**每周 5 次**的失败上限（重复申请也会计入）。
#   配置写错时在 staging 上试，别把正式额度烧掉。staging 证书浏览器不认，属正常。
#
# 幂等：已经有正式证书时直接退出，不会覆盖。

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(dirname "$SCRIPT_DIR")
COMPOSE_FILE=${COMPOSE_FILE:-$ROOT_DIR/compose.prod.yaml}
STAGING=0
while [ $# -gt 0 ]; do
    case "$1" in
        --staging) STAGING=1 ;;
        *) echo "未知参数：$1" >&2; exit 2 ;;
    esac
    shift
done

read_env() {
    local key=$1 default=${2:-} file="$ROOT_DIR/.env" line val
    [ -f "$file" ] || { printf '%s' "$default"; return; }
    line=$(grep -E "^[[:space:]]*${key}=" "$file" | tail -1 || true)
    [ -n "$line" ] || { printf '%s' "$default"; return; }
    val=${line#*=}
    val="${val%\"}"; val="${val#\"}"
    val="${val%\'}"; val="${val#\'}"
    printf '%s' "${val:-$default}"
}

DOMAIN=${DOMAIN:-$(read_env DOMAIN "")}
EMAIL=${LETSENCRYPT_EMAIL:-$(read_env LETSENCRYPT_EMAIL "")}

log() { printf '[init-tls] %s\n' "$*"; }
die() { printf '[init-tls] 失败：%s\n' "$*" >&2; exit 1; }

[ -n "$DOMAIN" ] || die "请先在 .env 里设置 DOMAIN（例：DOMAIN=otaku.example.com）"
[ -n "$EMAIL" ]  || die "请先在 .env 里设置 LETSENCRYPT_EMAIL（到期通知要用）"
[ -f "$COMPOSE_FILE" ] || die "找不到 compose 文件：$COMPOSE_FILE"

DC=(docker compose -f "$COMPOSE_FILE")

# 判断当前证书状态。用**退出码**表达，不靠输出文本：
#   0 = 有正式证书（可以跳过）
#   2 = 有 staging 证书（浏览器不认，必须换正式）
#   3 = 没有 / 文件损坏（需要从头签）
# 为什么要单独区分 staging：先跑 --staging 验证配置之后，再跑正式签发时
# 如果只看"文件存在"就会误判成"已签好"而静默跳过——这正是最坑的一种失败：
# 命令返回成功，站点却一直挂着浏览器不认的证书。
cert_state() {
    "${DC[@]}" run --rm --entrypoint sh certbot -c "
set -e
f=/etc/letsencrypt/live/$DOMAIN/fullchain.pem
[ -s \"\$f\" ] || exit 3
subj=\$(openssl x509 -in \"\$f\" -noout -subject 2>/dev/null) || exit 3
case \"\$subj\" in
  *CN*=*localhost*) exit 3 ;;
esac
issuer=\$(openssl x509 -in \"\$f\" -noout -issuer 2>/dev/null) || exit 3
case \"\$issuer\" in
  *STAGING*|*Fake*|*Pretend*) exit 2 ;;
esac
exit 0
" >/dev/null 2>&1
}

STATE=0
cert_state || STATE=$?

case "$STATE" in
    0)
        log "已有 $DOMAIN 的正式证书，跳过申请"
        log "（要强制重签：docker compose run --rm --entrypoint sh certbot -c 'rm -rf /etc/letsencrypt/live/$DOMAIN /etc/letsencrypt/archive/$DOMAIN /etc/letsencrypt/renewal/$DOMAIN.conf'）"
        exit 0
        ;;
    2)
        if [ "$STAGING" = "1" ]; then
            log "已有 staging 证书，跳过（要重签请先删除 live/$DOMAIN）"
            exit 0
        fi
        log "检测到 staging 证书 → 稍后会删除并申请**正式**证书"
        ;;
    *)
        log "没有可用证书（或文件损坏），从头开始"
        ;;
esac

if [ "$STATE" = "3" ]; then
    log "1/4 放置临时自签证书，让 Nginx 能启动"
    "${DC[@]}" run --rm --entrypoint sh certbot -c "
set -e
mkdir -p /etc/letsencrypt/live/$DOMAIN /etc/letsencrypt/archive/$DOMAIN
openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
  -keyout /etc/letsencrypt/archive/$DOMAIN/privkey1.pem \
  -out    /etc/letsencrypt/archive/$DOMAIN/fullchain1.pem \
  -subj   '/CN=localhost' >/dev/null 2>&1
cp /etc/letsencrypt/archive/$DOMAIN/fullchain1.pem /etc/letsencrypt/archive/$DOMAIN/chain1.pem
ln -sf /etc/letsencrypt/archive/$DOMAIN/privkey1.pem   /etc/letsencrypt/live/$DOMAIN/privkey.pem
ln -sf /etc/letsencrypt/archive/$DOMAIN/fullchain1.pem /etc/letsencrypt/live/$DOMAIN/fullchain.pem
ln -sf /etc/letsencrypt/archive/$DOMAIN/chain1.pem     /etc/letsencrypt/live/$DOMAIN/chain.pem
"
else
    log "1/4 已有可用的 staging 证书，跳过临时自签（它足够让 :80 应答 ACME）"
fi

log "2/4 启动 Nginx（--no-deps：只需要 :80 应答验证，不必等后端）"
"${DC[@]}" up -d --no-deps nginx

log "3/4 删掉假证书，向 Let's Encrypt 申请"
# 必须删：certbot 看到 live/$DOMAIN 已存在但没有对应的 renewal 配置会拒绝签发。
"${DC[@]}" run --rm --entrypoint sh certbot -c \
    "rm -rf /etc/letsencrypt/live/$DOMAIN /etc/letsencrypt/archive/$DOMAIN /etc/letsencrypt/renewal/$DOMAIN.conf"

ARGS=(certonly --webroot -w /var/www/certbot -d "$DOMAIN"
      --email "$EMAIL" --agree-tos --no-eff-email --non-interactive)
[ "$STAGING" = "1" ] && ARGS+=(--staging)

if ! "${DC[@]}" run --rm certbot "${ARGS[@]}"; then
    die "证书申请失败。常见原因：
  1) 域名没解析到本机 —— dig +short $DOMAIN 应返回本机公网 IP
  2) 80 端口没放通 —— 云厂商防火墙 + 本机 ufw 两层都要开
  3) 之前失败次数太多 —— 先用 --staging 验证配置，正式额度每周只有 5 次"
fi

log "4/4 reload Nginx 换上新证书"
"${DC[@]}" exec -T nginx nginx -s reload

log "完成。现在确认："
log "  curl -I https://$DOMAIN/            # 期望 200/301，且证书链完整"
log "  ./deploy/monitor.sh                 # 会显示证书剩余天数"
[ "$STAGING" = "1" ] && log "注意：这是 staging 证书，浏览器不信任。验证通过后去掉 --staging 重跑（需先删 live/$DOMAIN）"

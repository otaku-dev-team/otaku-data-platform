#!/usr/bin/env bash
#
# 证书续期 + 让 Nginx 重新加载。给 cron / systemd timer 每天跑一次。
#
#   ./deploy/renew-letsencrypt.sh
#
# Let's Encrypt 证书有效期 90 天，certbot 只会在剩余 < 30 天时真正续
# ——所以**每天跑是安全的**，没到期时它什么也不做，也不会消耗申请额度。
#
# 为什么每天都 reload：renew 之后证书文件已经换了，但 Nginx 进程还持着旧的，
# 不 reload 就仍然在用旧证书。每天 reload 一次代价极低（不断连接）。

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(dirname "$SCRIPT_DIR")
COMPOSE_FILE=${COMPOSE_FILE:-$ROOT_DIR/compose.prod.yaml}

log() { printf '[renew-tls] %s\n' "$*"; }

[ -f "$COMPOSE_FILE" ] || { echo "找不到 compose 文件：$COMPOSE_FILE" >&2; exit 1; }

DC=(docker compose -f "$COMPOSE_FILE")

# --quiet 只输出错误；退出码 0 表示「成功」或「还没到期，无需续」
if ! "${DC[@]}" run --rm certbot renew --webroot -w /var/www/certbot --quiet; then
    log "续期失败（证书快到期了，需要人工介入）"
    exit 1
fi

# renew 的退出码不区分"续了"和"没到期"，所以不判断是否需要 reload，直接 reload。
if ! "${DC[@]}" exec -T nginx nginx -s reload 2>/dev/null; then
    log "Nginx reload 失败（容器没起？续期本身可能已成功）"
    exit 1
fi

log "完成"

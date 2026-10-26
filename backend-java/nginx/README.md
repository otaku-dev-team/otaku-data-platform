# Nginx（生产反代 + HTTPS）

一个站点一个部署单元，公网只开 `80/443`，其余全部关在 compose 网络里：

```
公网 :80  ──▶ ACME 验证 / 301 跳 HTTPS
公网 :443 ──▶ nginx ──▶ backend:8080 ──▶ mysql:3306
```

| 文件 | 作用 |
|---|---|
| `nginx.conf` | 主配置（gzip、日志格式、`server_tokens off`）。这些必须写在 `http{}`，从 `conf.d` 补不了 |
| `templates/default.conf.template` | server 块。**是模板**：`${DOMAIN}` / `${BACKEND_UPSTREAM}` 由镜像 entrypoint 用 envsubst 注入 |

> 文件名带 `.template` 是官方镜像的约定：启动时把 `/etc/nginx/templates/*.template`
> 里的 `${VAR}` 换成容器环境变量，输出到 `/etc/nginx/conf.d/`。
> Nginx 自己的变量是 `$host` 这种不带花括号的写法，不会被误替换。

## 1. 首次部署顺序

```bash
cd backend-java
cp .env.production.example .env
# 填 DOMAIN / LETSENCRYPT_EMAIL / 三个口令 / OTAKU_PUBLIC_BASE_URL

docker compose -f compose.prod.yaml up -d --build   # 后端要跑 Flyway，等它 healthy
./deploy/init-letsencrypt.sh --staging               # 先 staging 验证配置
./deploy/init-letsencrypt.sh                         # 没问题再签正式证书
```

**`--staging` 不是可选项，是省额度的必要步骤。** Let's Encrypt 对同一域名有
「每周 5 次失败」的上限，重复申请也计入；配置写错时在 staging 上试，别把正式额度烧掉。
staging 证书浏览器不认，属正常。

### 为什么不能直接 `up` 完就完事

`ssl_certificate` 指向的文件不存在时，Nginx **根本不会启动**；而申请证书又需要
Nginx 在 `:80` 上应答 ACME 验证。鸡生蛋。所以 `init-letsencrypt.sh` 先放一张
1 天有效的自签证书让 Nginx 起来，签完再 reload 换成真的。

## 2. 域名与端口的前置条件

证书签发失败的三个原因，几乎全在这两条上：

1. **域名解析**：`dig +short <DOMAIN>` 必须返回本机公网 IP。
2. **80 端口可达**：云厂商安全组 **和** 本机防火墙（`ufw` / `iptables`）两层都要放通。
   Let's Encrypt 会从境外发起验证，只放通国内段不够。

```bash
dig +short otaku.example.com
curl -I http://otaku.example.com/.well-known/acme-challenge/test   # 应 404 而不是超时
```

## 3. 续期

```bash
# 每天跑一次，没到期时 certbot 什么也不做，不消耗额度
./deploy/renew-letsencrypt.sh
```

cron（root）：

```cron
# 每天 04:17 续期 + reload；输出进 syslog，失败时 cron 会发邮件
17 4 * * * cd /path/to/otaku-data-platform/backend-java && ./deploy/renew-letsencrypt.sh 2>&1 | logger -t otaku-tls
```

为什么每天 reload：`renew` 换了证书文件，但 Nginx 进程还持着旧的，不 reload 就还在用旧证书。
每天 reload 一次代价极低（不断连接）。

`./deploy/monitor.sh` 会报证书剩余天数，低于 14 天开始 WARN——**别等过期那天才发现**。

## 4. 上线后要改的三件事

| 项 | 现在 | 什么时候改 |
|---|---|---|
| `OTAKU_PUBLIC_BASE_URL` | `https://<DOMAIN>` | 首次配 `.env` 时就要写对，否则封面地址是 localhost |
| HSTS | **注释掉** | 证书续期跑通、域名稳定后再开。开了之后回退 HTTP 会让站点直接不可达 |
| 限流 | **注释掉** | 见下节 |

## 5. 限流：机制已就位，默认不启用

`nginx.conf` 里有两个 zone（注释状态），`default.conf.template` 里有对应的
`limit_req` 指令（同样注释）。启用只需取消注释 + `docker compose exec nginx nginx -s reload`。

**为什么默认不开**：命中限流返回 `429`，而 `docs/openapi.yaml` 的错误码表里没有这个码。
对外多一种状态码属于契约变更，要和客户端一起确认（Issue #188 还在等「公共读接口要不要 key」）。
在决定之前，这里是「随时能开」而不是「已经开了」。

真要开，建议先只压封面：

```nginx
limit_req_zone $binary_remote_addr zone=covers:10m rate=5r/s;
# location /api/covers/ 里：
limit_req zone=covers burst=20 nodelay;
limit_req_status 429;
```

封面是唯一有**回源成本**的接口（每次未命中都要去来源站抓），也是最容易被当图床的。
列表接口本来就有索引和 COUNT 缓存，压力性质不同。

## 6. 已经做掉的加固

| 项 | 做法 | 为什么 |
|---|---|---|
| `/internal/**` | 直接 `return 404` | 后端有 token 校验，这里是纵深防御：token 泄露之后仍然进不来 |
| `/actuator/*` | 只放 `/actuator/health` | `env` / `beans` / `metrics` 不该对公网说话 |
| `server_tokens` | `off` | 不暴露版本号 |
| 后端 8080 | 只绑 `127.0.0.1` | 公网只有 443 一个入口 |
| 证书挂载 | `letsencrypt` 卷对 nginx **只读** | nginx 被攻破也改不了证书 |

## 7. 排查

```bash
docker compose -f compose.prod.yaml logs --tail 100 nginx
docker compose -f compose.prod.yaml exec nginx nginx -t          # 配置语法
docker compose -f compose.prod.yaml exec nginx nginx -s reload   # 改完配置热加载
curl -I https://<DOMAIN>/                                        # 证书链 + 状态码
curl -s https://<DOMAIN>/actuator/health                         # 期望 {"status":"UP"}
curl -s -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/internal/import/batches   # 期望 404
```

`502` 是「nginx 起来了但后端没起」——先看 `docker compose ps` 里 backend 是不是 healthy。
后端首次启动要跑 Flyway，2 核机器上十几秒到几十秒都正常。

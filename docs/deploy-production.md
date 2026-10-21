# 生产部署（Linux 轻量应用服务器）

> **状态：服务器尚未到位。** 本文是把步骤先定下来，机器一到照着执行。
> **主责**：@pyxz0（`ROADMAP.md` §2.1 T3「生产化：部署方式、DB 迁移、鉴权/限流、健康检查与告警」）。
> 本文只是执行清单，不新增任何接口或字段约定。

---

## 1. 为什么要迁移

现在整套东西跑在一台开发机上：

| 组件 | 位置 |
|---|---|
| MySQL | `127.0.0.1:3310`，数据目录 `D:/tmp-otaku-mysql` |
| 后端 | `localhost:8080`，用 `./mvnw` 跑源码 |
| 客户端 | 桌面连 `127.0.0.1`，模拟器连 `10.0.2.2` |

**别人用不了**，而且这台机器一关机、一休眠、一清盘，服务就没了。目标状态：

```
手机 / 桌面 ──HTTPS──> Nginx ──> 后端 :8080 ──> MySQL（不对外）
                                     │
                                     └── 封面缓存（持久卷）
```

数据量参考：现有 15,445 条占 **285 MB**；全量 55.6 万约 **600–700 MB**，加上封面缓存，
一台 40 GB 系统盘的轻量服务器完全够用。

---

## 2. 服务器要求

| 项 | 最低 | 说明 |
|---|---|---|
| 系统 | Ubuntu 22.04 / 24.04（或选「Docker 镜像」） | 轻量应用服务器一般都能选 |
| 内存 | 2 GB | JVM 有 `MaxRAMPercentage=75`，MySQL buffer pool 默认给 256M；**2G 是能跑的底线，1G 不要试** |
| 磁盘 | 40 GB | 数据 + 封面缓存 + 日志 |
| 网络 | **公网 IP** | 只有内网的话外网客户端连不上，需要额外方案（见 §8） |
| 软件 | Docker + Docker Compose v2 | 选「Docker 镜像」最省事 |

---

## 3. 上线前必须改的配置

这一节是**最容易漏、漏了会出事**的地方。开发机的默认值拿到公网就是事故。

| # | 配置 | 开发值 | 生产必须 | 不改的后果 |
|---|---|---|---|---|
| 1 | `OTAKU_INTERNAL_TOKEN` | `dev-token` / 空 | `openssl rand -base64 32` | 空 → `/internal/**` 全部 401，同步进不来；用 `dev-token` → 谁都能灌数据 |
| 2 | `DB_PASSWORD` / `DB_ROOT_PASSWORD` | `otaku123` / `root-local-only` | 强随机 | 数据库被撞库 |
| 3 | MySQL 端口 | 宿主 `3307` 对外 | **只 `expose`、不 `ports`** | 公网可直连 MySQL |
| 4 | `OTAKU_PUBLIC_BASE_URL` | 留空（按请求 host 推导） | 显式写公网地址 | **见 §3.2，挂反代后封面全挂** |
| 5 | `logging.level.com.otaku` | `DEBUG` | `INFO` | 日志量暴涨，小磁盘几天就满 |
| 6 | `management.endpoint.health.show-details` | `always` | `never` | 健康检查把内部依赖、连接串细节暴露给任何人 |

第 5、6 项不用改代码——`compose.prod.yaml` 里已经用环境变量覆盖成 `INFO` / `never`。

### 3.2 为什么 `OTAKU_PUBLIC_BASE_URL` 必须显式设

`application.yml` 里这个值是 `public-base-url: ${OTAKU_PUBLIC_BASE_URL:}`，
留空时后端**按请求的 host 头推导**封面地址（`cover_url` 指向 `/api/covers/{work_id}`）。

本地这么干很方便：模拟器 `10.0.2.2`、桌面 `127.0.0.1`、真机局域网 IP 共用一套代码。

但一旦前面加了 Nginx：

```
客户端 → Nginx(443) → 后端(8080)
```

后端看到的是 Nginx 转发过来的请求。**如果 Nginx 没透传 `Host` / `X-Forwarded-Host`，
后端推导出来的是 `localhost:8080`，于是每个作品的 `cover_url` 都变成
`http://localhost:8080/api/covers/...`——客户端在自己手机上打开 localhost，封面全部裂开。**

两种解法，选一个：

- **推荐**：`OTAKU_PUBLIC_BASE_URL=https://otaku.example.com` 写死
- 或：Nginx 配 `proxy_set_header Host $host; proxy_set_header X-Forwarded-Proto $scheme;`

---

## 4. 部署步骤

### 4.1 拿到服务器后先做的事

```bash
# 确认 Docker 可用
docker --version && docker compose version

# 时区（影响日志时间，不影响业务：业务时间是 UTC 存的）
sudo timedatectl set-timezone Asia/Shanghai

# 拉代码
git clone https://github.com/otaku-dev-team/otaku-data-platform.git
cd otaku-data-platform/backend-java
```

### 4.2 配环境变量

```bash
cp .env.production.example .env
vi .env
```

必填四项：`DB_PASSWORD`、`DB_ROOT_PASSWORD`、`OTAKU_INTERNAL_TOKEN`、`OTAKU_PUBLIC_BASE_URL`。

生成口令：

```bash
openssl rand -base64 24   # 数据库口令
openssl rand -base64 32   # 内部令牌
```

> `.env` 已在 `.gitignore` 里，不会误提交。**别把它贴到群里或 Issue 里。**

### 4.3 起服务

```bash
docker compose -f compose.prod.yaml up -d --build
docker compose -f compose.prod.yaml ps        # 等两个都 healthy
docker compose -f compose.prod.yaml logs -f backend
```

首次启动会跑 Flyway 迁移建表，`start_period` 给了 60 秒。

### 4.4 迁移数据

**只迁一次**，之后线上的库就是权威数据。

**① 在开发机导出**（`--single-transaction` 不锁表，可边跑边导）：

```bash
# Windows 本机，MySQL 在 3310
/d/mysql/bin/mysqldump.exe -h127.0.0.1 -P3310 -uroot \
  --single-transaction \
  --set-gtid-purged=OFF \
  --default-character-set=utf8mb4 \
  otaku > otaku-$(date +%Y%m%d).sql
```

两个参数别省：

- `--set-gtid-purged=OFF`：MySQL 8 默认会写 `SET @@GLOBAL.gtid_purged=...`，导到非 GTID 环境会直接报错
- `--default-character-set=utf8mb4`：中文标题、简介不带这个会变问号

导出体积约 **300–400 MB**（库 285 MB，SQL 文本会更大）。

**② 传上去**：

```bash
scp otaku-20261022.sql user@<服务器IP>:/tmp/
```

**③ 在服务器导入**：

```bash
cd /path/to/otaku-data-platform/backend-java

# 先确认库是空的或确认可以覆盖
docker compose -f compose.prod.yaml exec mysql \
  mysql -uroot -p"$DB_ROOT_PASSWORD" -e "SHOW TABLES FROM otaku;"

# 导入
docker compose -f compose.prod.yaml exec -T mysql \
  mysql -uroot -p"$DB_ROOT_PASSWORD" otaku < /tmp/otaku-20261022.sql
```

> 用 `-T` 关掉 TTY，否则管道数据进不去。
>
> 这份 dump **包含 `flyway_schema_history`**，所以导入后 Flyway 认为已迁移到最新版本，
> 启动时不会重复建表。如果只想迁数据、让服务器自己建表，改用 `--no-create-info`
> 并且**不要**导 `flyway_schema_history`——两种方式别混。

**④ 核对**：

```bash
docker compose -f compose.prod.yaml exec mysql mysql -uroot -p"$DB_ROOT_PASSWORD" otaku -e "
SELECT source, COUNT(*) FROM work GROUP BY source;
SELECT COUNT(*) FROM work;
SELECT COUNT(*) FROM work WHERE release_year IS NOT NULL;
"
```

应当与开发机一致（当前：`otaku_site` 15,318 + `bangumi` 127 = **15,445**，其中有年份 13,656）。

### 4.5 把导出文件删掉

```bash
rm /tmp/otaku-20261022.sql    # 服务器上
rm otaku-20261022.sql         # 开发机上
```

里面是全量作品数据，别留在磁盘上。

---

## 5. 客户端指向线上

后端地址在客户端是**编译期常量**，通过 `--dart-define` 注入：

```bash
# 桌面
flutter build windows --dart-define=USE_MOCK=false \
  --dart-define=API_BASE_URL=https://otaku.example.com

# Android
flutter build apk --dart-define=USE_MOCK=false \
  --dart-define=API_BASE_URL=https://otaku.example.com
```

不传 `API_BASE_URL` 时会按平台取默认值（Android `10.0.2.2:8080`、其它 `127.0.0.1:8080`），
那是开发用的，发出去的包必须显式传。

### ⚠️ Android 明文 HTTP 的问题

Android 9+ 默认禁明文 HTTP。现在的放行配置在
`app-client/android/app/src/debug/res/xml/network_security_config.xml`，
**只对 debug 变体生效**，且只列了 `10.0.2.2` / `localhost` / `127.0.0.1` 与来源站。

所以：

- **上 HTTPS（推荐）**：用域名 + Let's Encrypt，release 包什么都不用改
- **只有公网 IP、只能用 http**：需要给 release 也配 `network_security_config.xml` 并加进
  `main` 清单，同时把该 IP 写进放行列表。这会降低整体安全性，属于妥协方案

---

## 6. 上线验收

在**外网**（手机流量，不是办公室 WiFi）逐条验，别只在服务器本机 curl：

```bash
# 1. 健康检查
curl -fsS https://otaku.example.com/actuator/health

# 2. 列表
curl -s "https://otaku.example.com/api/works?page=1&page_size=2" | head -c 400

# 3. 详情含 source_url
curl -s "https://otaku.example.com/api/works/<某个work_id>" | grep -o '"source_url":"[^"]*"'

# 4. 封面能出图（不是 502/404）
curl -sI "https://otaku.example.com/api/covers/<某个work_id>" | head -3

# 5. 内部接口对外必须 401
curl -s -o /dev/null -w "%{http_code}\n" -X POST \
  https://otaku.example.com/internal/import/batches \
  -H "Content-Type: application/json" -d '{"batch_id":"x","source":"x","items":[]}'
# 期望 401

# 6. MySQL 端口从外网不可达（应超时/拒绝）
nc -zv <服务器IP> 3306
```

再用客户端连一次，走完「列表 → 详情 → 登录 → 收藏 → 另一端可见」。

---

## 7. 运维

### 备份（最重要，别忘了）

```bash
# 每天 3 点备份，保留 14 天
cat > /etc/cron.daily/otaku-backup <<'EOF'
#!/bin/sh
set -e
cd /path/to/otaku-data-platform/backend-java
STAMP=$(date +%Y%m%d)
docker compose -f compose.prod.yaml exec -T mysql \
  mysqldump -uroot -p"$DB_ROOT_PASSWORD" --single-transaction --set-gtid-purged=OFF otaku \
  | gzip > /var/backups/otaku-$STAMP.sql.gz
find /var/backups -name 'otaku-*.sql.gz' -mtime +14 -delete
EOF
chmod +x /etc/cron.daily/otaku-backup
```

备份**没验证过等于没备份**：至少手动恢复一次到临时库，确认能起来。

### 日志与磁盘

```bash
docker compose -f compose.prod.yaml logs --tail 200 backend
docker system df                        # 镜像/卷占用
df -h
```

封面缓存会随访问增长（每张 webp 约几十 KB），挂的是 `cover-cache` 卷，不会撑爆容器。

---

## 8. 已知限制 / 还没定的

| 项 | 现状 | 影响 |
|---|---|---|
| **HTTPS** | 没有 | 需要 Nginx/Caddy + 证书；没有的话 Android release 包连不上 |
| **限流** | `LoginThrottle` 是内存实现 | **只能单实例**。多副本部署时各自计数，等于限流失效，要换 Redis |
| **封面缓存** | 本地磁盘卷 | 多实例会各存一份，切实例可能重新回源 |
| **只有内网 / IPv6** | 外网客户端连不上 | 需要公网 IP，或用 frp / Cloudflare Tunnel 之类的内网穿透——但那要求某台机器常开 |
| **谁运维** | 未定 | 备份是否有人看、磁盘满了谁处理 |
| **域名** | 未定 | 决定能不能上 HTTPS |

---

## 9. 一句话总结

服务器到位后，实际动作只有四步：**配 `.env` → `compose.prod.yaml up -d --build` →
`mysqldump` 导一次数据 → 客户端加 `--dart-define=API_BASE_URL` 重新打包**。

真正会踩坑的是 §3 那六项配置，尤其第 4 项（`OTAKU_PUBLIC_BASE_URL`）——它不会报错，
只会让所有人的封面变成一片空白，而且看起来像「图片接口坏了」。

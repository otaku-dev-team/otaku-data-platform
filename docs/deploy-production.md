# 生产部署（Linux 轻量应用服务器）

> **状态：服务器已就位（2026-10-26），按本文执行。**
> **进度与待决策事项见 [Issue #78](https://github.com/otaku-dev-team/otaku-data-platform/issues/78)。**
> **主责**：@pyxz0（`ROADMAP.md` §2.1 T3「生产化：部署方式、DB 迁移、鉴权/限流、健康检查与告警」）。
> 本文只是执行清单，不新增任何接口或字段约定。

---

## 0. 服务器准备清单（开机器的人照着买 / 配）

| # | 项 | 要求 | 不满足会怎样 |
|---|---|---|---|
| 1 | 系统 | Ubuntu 22.04 / 24.04（或直接选「Docker 镜像」） | 换发行版要改安装命令 |
| 2 | 规格 | **2 核 2 GB** 起，**40 GB 盘**；1 GB 内存不要试 | JVM + MySQL 抢内存，容器反复重启 |
| 3 | 公网 IP | 固定公网 IPv4 | 外网客户端连不上（内网穿透是另一套，见 §8） |
| 4 | 登录 | SSH **密钥** + sudo 用户，关掉密码登录 | 公网机器一天会被扫几千次 |
| 5 | 安全组 / 防火墙 | 只开 **22 / 80 / 443**；**不要**开 3306、8080 | 数据库或后端直接暴露在公网 |
| 6 | 软件 | Docker Engine + Compose **v2**（`docker compose version` 有输出） | `docker-compose` v1 语法不同，命令跑不起来 |
| 7 | 域名（要 HTTPS 才需要） | A 记录指向该 IP；**大陆服务器还要 ICP 备案**，否则 80/443 会被拦 | Android release 包连不上（它只认 HTTPS） |
| 8 | 数据通道 | 本机能 `scp` 到服务器；服务器 `/tmp` 至少 **2 GB** 空闲 | 452 MB 的 dump 传不上去 / 导入失败 |
| 9 | 备份落点 | 本机 `/var/backups` + **一份异地**（对象存储或另一台机器） | 整机挂了，备份跟着一起没 |
| 10 | 观测 | 云监控告警：**磁盘 > 80%**、内存、实例存活；留一个能收到告警的号 | 封面缓存把盘写满，没人知道 |
| 11 | 谁运维 | 指定一个人：看告警、清磁盘、定期做恢复演练 | 出事没人管（§8 这条一直没定） |

**上线前还要三个人点一次头**：对外服务属章程 §3.2 红线 4，公开前需 @zhengmin486 知情。
**对外暴露的三项必须一起配，否则会出现「代码有、线上没生效」**（Issue #188，zm 已拍板 A）：

| 配置 | 变量 | 不配的后果 |
|---|---|---|
| CORS 白名单 | `OTAKU_CORS_ALLOWED_ORIGINS` | 站点页面跨域读接口一律 403；留空只放行 localhost |
| 公共读限流 | `OTAKU_RATE_LIMIT_PUBLIC_PER_MINUTE` / `OTAKU_RATE_LIMIT_COVER_PER_MINUTE` | 被人拿脚本刷列表/封面，带宽与回源全算我们的 |
| 封面防盗链 | `OTAKU_COVER_ALLOWED_REFERERS` | 任意站点可把封面代理当免费图床（#189 的开关默认关） |

上了 Nginx/反代后还要把 `OTAKU_TRUST_FORWARDED_FOR=true`，否则限流会把所有请求都算到反代 IP 上。

### 0.1 机器到手先跑这段自检

```bash
# 系统与规格
head -2 /etc/os-release; nproc; free -h | head -2; df -h /

# Docker（要 Compose v2：`docker compose`，不是 `docker-compose`）
docker --version && docker compose version

# 监听端口（理想情况只有 sshd；装了 Docker 后可能多几个 docker-proxy）
ss -lntp | head

# 出网与时间
curl -fsS -o /dev/null -w "outbound %{http_code}\n" https://www.baidu.com
timedatectl | head -3
```

这四组都对（系统、Docker v2、只开必要端口、能出网），就可以进 §3 了。

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

数据量参考：现有 **571,660 条**（bangumi 556,342 + otaku_site 15,318），迁移 dump
**452 MB**（`otaku-full-20261022.sql`）。服务端磁盘给「库 + 导入中转的同一份 dump」留
**2–3 GB** 即可，40 GB 系统盘绰绰有余——真正会持续增长的是封面缓存（挂卷，按访问量涨）。

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

### 4.3 起服务（首次上线：**先只起 MySQL**）

```bash
# 首次上线：先只起 MySQL，把 backend 留到 §4.4 数据导入之后再起
docker compose -f compose.prod.yaml up -d mysql
docker compose -f compose.prod.yaml ps          # 等 mysql healthy

# 数据导入并核对完成后（§4.4 ④），再起后端
# docker compose -f compose.prod.yaml up -d --build backend
```

**为什么首次要这个顺序**：迁移 dump 里的 `flyway_schema_history` 只到 **V6**，库里没有
`work_tag` / `schedule` / `article` 三张表——它们由 **V7–V9** 在后端首次启动时建，
其中 V7 还要从 `work` 回填约 222 万行标签（2C2G 机器上**一两分钟**，别当成卡死）。
先起后端再导数据的话，历史会被 dump 回退到 V6，V7–V9 白跑一遍。

之后的重启与升级就正常 `up -d --build` 即可。

### 4.4 迁移数据

**只迁一次**，之后线上的库就是权威数据。

**① 在开发机导出并验证**

用脚本，别手拼参数（漏一个参数不会当场报错，要到恢复时才炸）：

```bash
# 本机 MySQL 在 3310，客户端在 /d/mysql/bin
MYSQL=/d/mysql/bin/mysql.exe MYSQLDUMP=/d/mysql/bin/mysqldump.exe \
  DB_PORT=3310 DB_USER=root DB_PASSWORD= \
  ./scripts/dump-db.sh --out /d/otaku-migration/otaku-full.sql --verify
```

`--verify` 会建一个临时库（`otaku_migrate_check`）把 dump 导进去，逐表比对
**行数 + 逐行内容指纹**（`SUM(CRC32(...))`），比对完删掉临时库。

**校验没通过就不要往下走**——脚本失败时退出码是 1，可以直接拿去做前置检查。

> 为什么要比指纹而不只比行数：行数对得上、内容却被截断或编码坏掉的情况是存在的，
> 而行数看不出来。我之前在脚本里写错过一个列名，两边都返回空值，于是「空 == 空」
> 被判成通过——这种假阳性只有把「取不到值」也当成失败才能堵住。

等价的单条命令（手工跑时）：

```bash
/d/mysql/bin/mysqldump.exe -h127.0.0.1 -P3310 -uroot \
  --single-transaction --set-gtid-purged=OFF \
  --default-character-set=utf8mb4 \
  --result-file=D:/otaku-migration/otaku-full.sql otaku
```

两个参数别省：

- `--set-gtid-purged=OFF`：MySQL 8 默认会写 `SET @@GLOBAL.gtid_purged=...`，导到非 GTID 环境会直接报错
- `--default-character-set=utf8mb4`：中文标题、简介不带这个会变问号

用 `--result-file=` 而不是 shell 的 `>`：Git Bash 下重定向会参与换行/编码转换。

**导出体积 452 MB**（571,660 条）。旧文档里那个「16 MB / 15,445 条」是 8 月小库时代的数字，
全量灌入后已作废——拿它核对会以为少导了 55 万条。服务器磁盘按 2–3 GB 留余量（库 + 中转的 dump）。

**2026-10-22 实测记录**（这份 dump 已用 `scripts/dump-db.sh --verify` 恢复校验，可直接用）：

| 项 | 值 |
|---|---|
| 文件 | `otaku-full-20261022.sql`，473,802,286 字节（452 MB） |
| SHA256 | `744cf46d2b9b0676cc08c81f9800452755fe6401e0eefc7832cf30869acbeaea` |
| 表数量 | 7：`work` / `app_user` / `user_session` / `collection` / `import_batch` / `import_batch_run` / `flyway_schema_history` |
| `work` | **571,660** 行（bangumi 556,342 + otaku_site 15,318），逐行 CRC32 指纹 `1227192616237647` |
| `flyway_schema_history` | **只到 V6**——dump 里没有 V7 的 `work_tag`，也没有 V8/V9 的档期与资讯表 |
| 恢复验证 | 导入临时库后逐表行数 + 逐行内容指纹一致 |

> ⚠️ 正因为 dump 停在 V6，**导完数据再起 backend**（见 §4.3）：V7–V9 会在后端首次启动时补跑，
> V7 的标签回填约 222 万行，2C2G 机器上一两分钟，属于正常。

**② 传上去**：

```bash
scp otaku-full-20261022.sql user@<服务器IP>:/tmp/
```

**③ 在服务器导入**：

```bash
cd /path/to/otaku-data-platform/backend-java

# 先确认库是空的或确认可以覆盖
docker compose -f compose.prod.yaml exec mysql \
  mysql -uroot -p"$DB_ROOT_PASSWORD" -e "SHOW TABLES FROM otaku;"

# 导入
docker compose -f compose.prod.yaml exec -T mysql \
  mysql -uroot -p"$DB_ROOT_PASSWORD" otaku < /tmp/otaku-full-20261022.sql
```

> 用 `-T` 关掉 TTY，否则管道数据进不去。452 MB 在 2C2G 上大约 **1–3 分钟**。
>
> 这份 dump **包含 `flyway_schema_history`，但只到 V6**。所以导完数据、起 backend 时，
> Flyway 会补跑 V7（`work_tag` 回填）/ V8（档期）/ V9（资讯）——**这是预期行为**，不是重复建表。
> 反过来，如果你只想迁数据、让服务器自己建全部表，就改用 `--no-create-info` 且
> **不要导** `flyway_schema_history`——两种方式别混（混了会出现「表在、历史没有」）。

**④ 核对**：

```bash
docker compose -f compose.prod.yaml exec mysql mysql -uroot -p"$DB_ROOT_PASSWORD" otaku -e "
SELECT source, COUNT(*) FROM work GROUP BY source;
SELECT COUNT(*) FROM work;
SELECT COUNT(*) FROM work WHERE release_year IS NOT NULL;
"
```

应当与开发机一致：`otaku_site` 15,318 + `bangumi` **556,342** = **571,660**，其中有年份 **520,152**（91%）。

### 4.5 把导出文件删掉

```bash
rm /tmp/otaku-full-20261022.sql    # 服务器上
rm otaku-full-20261022.sql         # 开发机上
```

里面是全量作品数据，别留在磁盘上。

### 4.6 起 Nginx 并申请证书

首次上线按这个顺序（**第 2 步别跳**）：

```bash
# 1) 确认域名已解析到本机，80/443 在安全组与本机防火墙都放通（§0 第 5 条）
dig +short otaku.example.com            # 应返回本机公网 IP
curl -I http://otaku.example.com/.well-known/acme-challenge/x   # 应 404，不是超时

# 2) 签证书（先 staging）。这一步会自己完成引导：
#    放一张 1 天自签证书 → 起 nginx（--no-deps）→ 申请 → reload
./deploy/init-letsencrypt.sh --staging

# 3) 确认渲染后的配置真的合法（第一次务必跑）
docker compose -f compose.prod.yaml exec nginx nginx -t

# 4) 换正式证书：脚本检测到 staging 证书会自动删除并重新签发
./deploy/init-letsencrypt.sh

# 5) 起全套
docker compose -f compose.prod.yaml up -d
```

**为什么不先手动 `up -d nginx`**：`ssl_certificate` 指向的文件不存在时 Nginx 起不来，
会一直 restart；而签发证书又需要 Nginx 在 `:80` 应答 ACME，鸡生蛋。
`init-letsencrypt.sh` 先放一张自签证书把这一圈解开——**所以第 2 步不能跳过，
也不能用 `up -d nginx` 替代**。细节与排查见 `backend-java/nginx/README.md`。

**为什么先 staging**：Let's Encrypt 对同一域名有每周 5 次失败上限（重复申请也计入）。
配置写错时在 staging 上试，别烧正式额度。

**关于 8080**：`compose.prod.yaml` 默认把后端绑在 `127.0.0.1`，公网只有 443 一个入口
（与 §0 第 5 条一致）。要在别的机器上直连调试，在 `.env` 里设 `BACKEND_BIND=0.0.0.0`
并限制来源 IP；调完改回来，否则等于绕过 Nginx 的全部加固。

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

### Android 明文 HTTP 的问题

Android 9+ 默认禁明文 HTTP。现在的放行配置在
`app-client/android/app/src/debug/res/xml/network_security_config.xml`，
**只对 debug 变体生效**，且只列了 `10.0.2.2` / `localhost` / `127.0.0.1` 与来源站。

所以：

- **上 HTTPS（推荐）**：用域名 + Let's Encrypt，release 包什么都不用改
- **只有公网 IP、只能用 http**：需要给 release 也配 `network_security_config.xml` 并加进
  `main` 清单，同时把该 IP 写进放行列表。这会降低整体安全性，属于妥协方案

---

## 6. 上线验收

在**外网**（手机流量，不是办公室 WiFi）逐条验，别只在服务器本机 curl。
下面这批断言在 CI 的 `deploy-lint` / `stack` 作业里已经自动化（每次改部署配置都会跑），
这里保留手工版是为了**在外网真实链路上**再验一次——CI 验的是本机回环。

```bash
# 1. 健康检查
curl -fsS https://otaku.example.com/actuator/health

# 2. 列表
curl -s "https://otaku.example.com/api/works?page=1&page_size=2" | head -c 400

# 3. 详情含 source_url
curl -s "https://otaku.example.com/api/works/<某个work_id>" | grep -o '"source_url":"[^"]*"'

# 4. 封面能出图（不是 502/404）
curl -sI "https://otaku.example.com/api/covers/<某个work_id>" | head -3

# 5. 内部接口对外必须不可用（Nginx 收口 → 404，请求根本没到后端）
curl -s -o /dev/null -w "%{http_code}\n" -X POST \
  https://otaku.example.com/internal/import/batches \
  -H "Content-Type: application/json" -d '{"batch_id":"x","source":"x","items":[]}'
# 期望 404

# 5b. token 校验本身仍在：在服务器本机绕过 Nginx 直连后端
curl -s -o /dev/null -w "%{http_code}\n" -X POST \
  http://127.0.0.1:8080/internal/import/batches \
  -H "Content-Type: application/json" -d '{"batch_id":"x","source":"x","items":[]}'
# 期望 401

# 6. MySQL 端口从外网不可达（应超时/拒绝）
nc -zv <服务器IP> 3306
```

再用客户端连一次，走完「列表 → 详情 → 登录 → 收藏 → 另一端可见」。

---

## 7. 运维

### 备份

```cron
# 每天 03:10 备份（root 的 crontab）
10 3 * * * cd /path/to/otaku-data-platform/backend-java && ./deploy/backup.sh 2>&1 | logger -t otaku-backup
```

`deploy/backup.sh` 里有四个不是"顺手加的"设计：

| 做法 | 为什么 |
|---|---|
| 流式 gzip，不落中间文件 | 2C2G 机器上，先 dump 到磁盘再压会让磁盘与内存峰值叠加 |
| 先写 `.part` 再 `mv` | 进程被 OOM kill 时不会留下一个**看起来正常、实际截断**的 .sql.gz |
| `gzip -t` + 大小下限 | 损坏的备份等于没有备份，宁可这次失败 |
| 按 `${SITE_KEY}-*.sql.gz` 保留 14 天 | 只删自己前缀，不碰同目录里别的文件 |

口令不出容器：`mysqldump` 在 mysql 容器里跑，读容器自己的 `$MYSQL_ROOT_PASSWORD`，
宿主机不需要、也不应该再存一份。

备份**没验证过等于没备份**：至少手动恢复一次到临时库，确认能起来。

### 巡检与证书续期

```cron
# 每天 04:17 巡检 + 04:19 续期证书
17 4 * * * cd /path/to/otaku-data-platform/backend-java && ./deploy/monitor.sh --quiet 2>&1 | logger -t otaku-monitor
19 4 * * * cd /path/to/otaku-data-platform/backend-java && ./deploy/renew-letsencrypt.sh 2>&1 | logger -t otaku-tls
```

`deploy/monitor.sh` 查五件事：后端健康、容器状态、磁盘阈值、**备份新鲜度（< 26h）**、
证书剩余天数（< 14 天开始 WARN）。任一失败退出码非 0，cron 会因此发邮件。

**「该有哪些容器 / 要不要验证书」是显式配置，不是自动探测**（`.env`）：

| 变量 | 默认 | 什么时候改 |
|---|---|---|
| `EXPECT_SERVICES` | `otaku-backend otaku-mysql otaku-nginx` | 没有启用 nginx 的联调形态：去掉 nginx |
| `EXPECT_TLS` | `1` | 没有域名 / 没有 HTTPS 时设 `0`，否则每天报「取不到证书」 |

刻意不做「容器不存在就跳过」的自动探测：那样 nginx 被误删、起不来都会被静默放过，
巡检就退化成「什么都不查也报通过」。

> **从 Windows 拷贝脚本的坑**：仓库在 Windows 上检出是 CRLF，`scp` 到 Linux 后 shebang 会变成
> `bash\r`，报 `No such file or directory`。传之前先 `sed -i 's/\r$//' deploy/*.sh`。

用 `--quiet`：它只在出问题时说话。每天一封"一切正常"的邮件，等于把所有告警都训练成噪音。

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
| **HTTPS** | 已提供（`backend-java/nginx/` + `deploy/init-letsencrypt.sh`） | 仍需域名解析到位、80/443 放通；步骤见 §4.6 与 `nginx/README.md` |
| **限流** | `LoginThrottle` 是内存实现 | **只能单实例**。多副本部署时各自计数，等于限流失效，要换 Redis |
| **封面缓存** | 本地磁盘卷 | 多实例会各存一份，切实例可能重新回源 |
| **只有内网 / IPv6** | 外网客户端连不上 | 需要公网 IP，或用 frp / Cloudflare Tunnel 之类的内网穿透——但那要求某台机器常开 |
| **谁运维** | 未定 | 备份是否有人看、磁盘满了谁处理 |
| **域名** | 未定 | 决定能不能上 HTTPS |

---

## 9. 新站接入：接单前清单与时间预算

> **目标**：接单后 3 天内部署新站，第 3 天用户能用上 App。
> 目标与分级的权威出处是 [`deployment-requirement.md`](deployment-requirement.md) 与
> [`deployment-schedule.md`](deployment-schedule.md)（2026-10-26 由负责人补齐并拍板 3 天）。
> 本节只保留**执行视角**的那一半：从哪天算、必须拿到什么、每一步真实要多久。

### 9.1 接单前必须拿到的东西（缺一项就不能承诺 3 天）

| # | 要什么 | 谁给 | 缺了会怎样 |
|---|---|---|---|
| 1 | **该站自己的域名** | 站方 | 没有域名就没有 HTTPS；Android release 包也连不上明文 HTTP（§5） |
| 2 | 域名解析权限（或授权我们加 A 记录） | 站方 | 证书签不下来，且 DNS 生效时间不可控 |
| 3 | 服务器（或授权我们买） | 站方 / 我们 | 后续全部步骤停摆 |
| 4 | 安全组放通 22 / 80 / 443 | 站方 | ACME 验证失败、客户端连不上（§0 第 5 条） |
| 5 | 数据导出（dump）或只读接口 | 站方 | 只能跑一个空站 |
| 6 | 品牌资源（应用名 / 图标 / 包名） | 站方 | 打出来的包是别人的牌子（W1） |
| 7 | 一个负责后续运维的人 | 站方 / 我们 | 告警没人看、磁盘满了没人清（§0 第 11 条一直没定） |

**第 1–4 项全部由站方掌握，我们代劳不了。** 这四项到位的那一天，才是「3 天」的第 0 天。

### 9.2 时间预算（按现在实际能跑的步骤倒推，非拍脑袋）

| 阶段 | 内容 | 预算 | 现在靠什么保证 |
|---|---|---|---|
| D0 | `.env` → `init-letsencrypt.sh` → `up -d` | 2 小时 | CI 的 `deploy-lint/stack` 每次改部署配置都把整套栈真起一遍 |
| D1 | dump 导出 → 迁移 → Flyway V6→V9 | 2–4 小时 | 迁移有集成测试；**真实体量尚未演练**（仓库里没有 dump） |
| D1 | §6 八条验收 + 客户端真机 | 2 小时 | 八条已自动化（本机回环）；外网链路仍需手工 |
| D2 | 客户端打包 / 签名 / 分发 | 0.5 天 | 属 W1 / P5（客户端模块），不在本文范围 |
| — | 缓冲 | 1 天 | |

**「3 天」的真实约束不在工程，而在 §9.1 的前四项。** 前置拖一天，承诺就不成立——
这该写进接单前的确认，而不是等部署当天才发现。

### 9.3 已经预建好的（接单后不用现做）

| 能力 | 位置 |
|---|---|
| 反代 + HTTPS 引导 | `backend-java/nginx/`、`deploy/init-letsencrypt.sh` |
| 备份 / 巡检 / 证书续期 | `deploy/backup.sh`、`deploy/monitor.sh`、`deploy/renew-letsencrypt.sh` |
| 部署配置正确性 | CI `deploy-lint`（compose 解析、`nginx -t`、整套栈起停、备份可恢复、巡检阈值） |
| 单站隔离校验 | `scripts/check-site-isolation.py`（新增站名硬编码会红） |

---

## 10. 一句话总结

服务器到位后，实际动作只有四步：**配 `.env` → `compose.prod.yaml up -d --build` →
`mysqldump` 导一次数据 → 客户端加 `--dart-define=API_BASE_URL` 重新打包**。

真正会踩坑的是 §3 那六项配置，尤其第 4 项（`OTAKU_PUBLIC_BASE_URL`）——它不会报错，
只会让所有人的封面变成一片空白，而且看起来像「图片接口坏了」。

---

## 11. 实况记录：2026-10-27 首次真机部署（联调形态）

> 这一节不写「应该怎样」，只写**机器上现在到底是什么**。命令与输出都实际跑过；
> 与前面章节冲突时，以本节为准，并回来改前面。

### 11.1 现在的形态

| 项 | 值 |
|---|---|
| 机器 | 腾讯云 Lighthouse `154.8.194.198`（Ubuntu 24.04，2 核 2 GB，50 GB 盘，Swap 1.9 GB） |
| 部署目录 | `/opt/otaku/backend`（`pyxz0` 所有；`.env` 600，未入库） |
| 进程 | `otaku-mysql` + `otaku-backend` 两个容器；**nginx 未启用**（没有域名、且 80 被现网站点占用） |
| 对外地址 | `http://154.8.194.198:8080` —— 公网直连，无 HTTPS |
| 镜像构建 | 本地 `./mvnw package` 出 jar → 服务器 `BACKEND_DOCKERFILE=Dockerfile.runtime` 组装（25 秒）；**不在 2G 机器上跑 Maven** |
| 数据 | 只有导入链路的样例：3 条作品 / 9 条 Flyway 迁移；**全量 57.1 万未导**（没有 dump） |
| 备份 | 每日 03:10 → `/opt/otaku/backups`，保留 14 天；已做一次恢复演练 |
| 巡检 | 每日 04:17（`--quiet`，只在失败时说话） |
| 时区 | `Asia/Shanghai`（`TZ` 同时给了容器和 JVM） |

### 11.2 部署时踩到、已写进仓库的五件事

1. **服务器拉不到 Docker Hub**（`registry-1.docker.io` 直连超时，连 hello-world 都过不去）。
   改用腾讯云内网镜像 `mirror.ccs.tencentyun.com`（`/etc/docker/daemon.json` → `registry-mirrors`），
   之后 `mysql:8.0` / `eclipse-temurin:17-jre-jammy` 都是秒级。
   顺带在同一个文件里配了 `log-opts`（单文件 20 MB × 3），否则容器日志会把 50 GB 盘写满。
2. **2 GB 机器必须给容器设上限**：不设时 MySQL 按宿主机内存自算，和 JVM 抢到整机 OOM。
   现在 `MYSQL_MEM_LIMIT=768m`、`BACKEND_MEM_LIMIT=768m`，实测占用 432 MiB / 200 MiB，
   同机现网站点（uvicorn :8000）在部署前后均 200。
3. **备份的大小下限会挡住「空库」**：`MIN_SIZE_KB` 默认 1 MB，空库 dump 只有 8 KB，
   脚本会判失败——这是设计意图（挡「连不上却写出几 KB 文件」）。空库验收期在 `.env` 里临时写
   `MIN_SIZE_KB=4`，**导入全量数据后必须删掉这行**。
   2026-10-28 已删除（当时库内 5 万条真实数据），并做了一次**恢复演练**：把最新备份导进临时库，
   `work` / `work_tag` / `import_batch` / `flyway` 最高版本与线上一致，说明这份快照可还原。
   只验「文件大小非零」是不够的——备份没恢复过就不算备份。
4. **cron 不继承登录环境**：`backup.sh` / `monitor.sh` 自己读 `.env`（不 `source`，避免执行文件内容），
   compose 也从 compose 文件所在目录自动加载 `.env`。已用 `env -i PATH=/usr/bin:/bin` 实测两个脚本都能跑通。
5. **长任务期间发版会打断写端**：全量导入（业务侧 `python -m sync` → `/internal/import/batches`）
   每批约 2 分钟一次，而它的重试窗口只有 3 次 × 2 秒 ≈ 6 秒；后端重建要 20–40 秒，
   直接 `up -d` 会让批次失败、整轮导入退出（数据幂等，但要从头重扫）。
   做法：`kill -STOP <sync pid>` 冻住写端 → 重建后端 → `kill -CONT <sync pid>` 恢复。
   2026-10-28 实测：重启后批次 122 → 125、作品与封面计数继续增长、后端 5 分钟日志 0 错误。

### 11.3 已实测过的（附证据方式）

| 项 | 怎么验的 | 结果 |
|---|---|---|
| 公网可达 | 从开发机 `curl http://154.8.194.198:8080/actuator/health` | 200 `{"status":"UP"}` |
| 空库自动迁移 | 看容器日志 | 9 个迁移全部应用，7.6 秒启动完成 |
| 导入链路 | `POST /internal/import/batches` 两批样例 | 3 插入 / 2 更新 / 4 按规则拒收 |
| 列表 + 分页 | `GET /api/works?page=1&page_size=5` | `total=3`，`cover_url` 已按 `OTAKU_PUBLIC_BASE_URL` 改写 |
| 封面代理 + 缓存 | `GET /api/covers/{work_id}` 连取两次 | 首次回源 97 KB webp，二次 0.18 s（命中缓存） |
| 内部接口隔离 | 公网 `POST /internal/import/batches`（不带令牌） | 401 |
| 备份可恢复 | 恢复进 `restore_check` 库后比对 | `work` 3/3、`flyway_schema_history` 9/9 一致 |
| 备份可恢复（真实数据） | 48,689 条时把最新备份导进临时库 | `work` 48,689 / `work_tag` 228,680 / `flyway` 12，与线上一致（差值＝快照后仍在写） |
| 公共读接口在 5 万条下 | 本机 curl 各接口 | 列表 16.7 ms、深页（偏移 4 万）20.7 ms、标签筛选 4.6 ms、详情 2.3 ms、`/api/tags` 冷 226 ms → 命中 6–20 ms（缓存见 PR #230） |
| 巡检会失败 | `DISK_MAX_PCT=1` / 期望一个不存在的容器 | 均 exit 1，且原因对得上 |

### 11.4 还不是「上线」——差什么

| 差什么 | 卡在哪 | 谁动 |
|---|---|---|
| HTTPS（D-2） | 没有域名。Let's Encrypt 不给 IP 签证书 | 商务侧给域名 + 解析 |
| 全量数据（D-3） | dump 已在服务器上，导入进行中（2026-10-28 00:25 时 9.1%，约 17–28 小时） | 无需外部输入，跑完做终态核对 |
| 正式反代形态 | 机器上 80 端口被现网站点占着；启用 nginx 要先决定端口与站点归属 | 部署时定 |
| 告警出口（D-8） | 现在只有 cron 邮件，没人收 | 云监控告警 + 值班人 |
| 上线前点头 | 章程 §3.2 红线 4：对外服务需 @zhengmin486 知情 | zm |

### 11.5 切回正式形态的顺序（域名到位那天照着做）

1. `.env`：`DOMAIN=<域名>`、`OTAKU_PUBLIC_BASE_URL=https://<域名>`、`BACKEND_BIND=127.0.0.1`，
   去掉 `EXPECT_SERVICES` / `EXPECT_TLS` 这两行；`NGINX_HTTP_PORT` 按机器上空出来的端口定。
2. `./deploy/init-letsencrypt.sh --staging` → 通了再正式签（顺序见 §4.6，别先手动起 nginx）。
3. `docker compose -f compose.prod.yaml up -d`（这次带上 nginx）。
4. 重跑本节 11.3 的表，外网换成域名 + `https://`。
5. 打开 `renew-letsencrypt.sh` 的 cron，把 `EXPECT_TLS` 恢复默认。

### 11.6 站主后台（V10）已上线

2026-10-27 下午把首版站主后台（Issue #144）部署到同一台机器，**V10 迁移在生产库上真跑过**。

| 项 | 实测 |
|---|---|
| 迁移 | `otaku` 库 v9 → v10，`Successfully applied 1 migration`（0.4 秒），服务 8.4 秒启动 |
| 页面 | `http://154.8.194.198:8080/console/` → 200 `text/html`（20 KB，零依赖单文件） |
| 开通 | `POST /internal/sites`（site_key=otaku，sources=[otaku_site]）→ 201；`POST /internal/site-admins` → 201 |
| 概览 | 作品 3（anime 2 / comic 1），来源 `otaku_site`，未配来源时不会退化成看全库 |
| 用户 | 列表只含本站账号；跨站/未归属账号 403，不存在 404（见集成测试） |
| 禁用 | `revoked_sessions=1`；旧令牌立刻 401；原密码重登 403 `USER_DISABLED`；解禁后 200 |
| 同步 | 读到既有 2 次导入运行，`partial`（4 条拒收），失败条目带 `source_id` |
| 鉴权面 | 公网 `/internal/sites` → 401；`/api/console/overview` 无令牌 → 401；两套令牌互不通用（各 401） |
| 回归 | `/api/works`、`/api/articles` 仍 200 |

运维注意：

- 后台账号与站点**只能**由 `/internal/**` 开通（令牌只在平台侧），后台页面里没有开通入口；
- 线上的演示账号 `console-demo-user`（`site_key=otaku`）只是为了让站主后台有数据可看，
  不再需要时按 `/internal/accounts` 的账号删除流程处理（直接删 `app_user` 行即可，注意先清 `user_session`）；
- 站主账号密码只存在服务器 `/opt/otaku/backend/.console-demo-credentials`（600），**不入库、不入仓库**。

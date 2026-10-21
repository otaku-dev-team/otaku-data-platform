# backend-java

Java 业务后端。负责人：**Java 负责人**（@pyxz0）。

## 职责

- 提供作品查询、搜索与详情接口。
- 提供账号注册、登录、当前用户与退出能力，并管理多设备会话。
- 管理个人收藏与观看状态，保证用户只能访问自己的数据。
- 提供内部导入接口，供 Python 同步作业写入作品数据。
- 负责数据库模型、迁移与持久化。

## 边界

- 是**唯一写入业务数据库**的模块。Python 不直接写库，Flutter 不直接访问数据源。
- 内部导入接口仅供同步作业调用，需与面向客户端的接口分开认证。
- 作品数据同步不得覆盖账号、收藏与个人状态等用户数据。

## 状态

| 范围 | 状态 |
| --- | --- |
| 工程脚手架（Spring Boot 3.5.16 / JDK 17 / MySQL 8 / Flyway） | ✅ 已建立 |
| 接口② 内部导入 + 批次查询 | ✅ 已实现 |
| 接口③ 作品列表 / 搜索 | ✅ 已实现 |
| 接口④ 作品详情 | ✅ 已实现 |
| 封面代理 + 本地缓存（契约要求，openapi 未定义） | ✅ 已实现 |
| 单元测试 | ✅ 31 项，`mvnw.cmd test` 通过（含对外 JSON 键名形状测试） |
| 启动与鉴权冒烟 | ✅ `java -jar` 5–6 秒内启动；无/错令牌 POST 均返回 `401 {"error":{"code":"UNAUTHORIZED"}}` |
| 数据侧验收 D1–D10 | ✅ 已在真实 MySQL 8.0.46 实例上逐条跑通，见下节 |
| 容器化本地环境 | ✅ `compose.yaml` 起 MySQL 8.0.46（:3307），`local` profile 直连验证过 D1/D2、列表、封面 |
| 真实 Python 同步联调 | ✅ 真实站点 100 条动画经 `sync-python` 入库，重跑 `unchanged=100`，见下节 |
| 阶段 2：账号、会话、收藏与观看状态 | ✅ 已实现，C1–C11 与 E7 全部实测通过，契约提案见 `stage2-account-collection.md` |
| Flutter 客户端联调 | ⬜ 本机无 Flutter SDK，未运行；接口形状已用 `ContractJsonShapeTest` 对齐 |

## 数据侧验收实测结果（D1–D10）

在独立的 MySQL 8.0.46 实例上跑过一遍（临时实例，端口 3307，未影响本机 3306）：

| 项 | 结果 |
| --- | --- |
| D1 导入 50–100 条 | ✅ 首轮 `inserted=3`，与提交条数一致 |
| D2 同批连跑两次 | ✅ 第二轮 `inserted=0, unchanged=3`，作品数不增长 |
| D3 改 `main_rating` 后重导 | ✅ 8.50 → 9.90，`updated=1`，`work_id` 未变 |
| D4 `summary` 置空后重导 | ✅ `unchanged=1`，库中简介保持原值 |
| D5 伪造空 title | ✅ `rejected` + `TITLE_REQUIRED`，同批其他记录不受影响（另含 `INVALID_TYPE`、`RATING_OUT_OF_SCALE`、`SOURCE_ID_REQUIRED`） |
| D6/D2 重复提交 | ✅ 幂等由 `uk_work_source` 保证，无重复作品 |
| D7 不带内部令牌 | ✅ `401 UNAUTHORIZED`，数据无变化 |
| D8 换行清洗 | ✅ 入库 `summary` 中 `\r` 数量为 0 |
| D9 长文本完整 | ✅ 6413 字载荷入库 6412 字（`\r\n`→`\n` 少 1 字节），未截断 |
| D10 同名不合并 | ✅ 判定链只认 `(source, source_id)`，未做标题合并 |
| B2 `page_size` 上限 | ✅ 传 100 返回 `page_size=50` |
| 列表/详情/错误码 | ✅ 无结果 200+空数组、`page` 越界 200+空数组、`q` 通配符已转义、`type` 非法 400、详情不存在 404、501 条 413、坏 JSON 400 |
| 封面代理 | ✅ 首次回源返回 `image/webp` 并落盘，二次命中缓存；无封面返回 404 |

> 这一轮实测抓到一个真实缺陷并已修复：MySQL 的 JSON 列读回来会把 `["a","b"]` 格式化成 `["a", "b"]`，
> 直接做字符串比较会让 tags 每次都判定"变了"，D2 的 `unchanged` 变成 `updated`。
> 现在读库时统一经 `TagsJson.canonical()` 规范化，并有回归测试兜住。

## 与 sync-python 的真实联调结果

用真实来源站跑了一次完整链路（`sync-python` → 本服务 → MySQL）：

```bash
# 1. 起库与后端（见"快速开始"）
# 2. 跑同步作业
cd sync-python
PYTHONPATH=src OTAKU_INTERNAL_TOKEN=dev-token OTAKU_JAVA_BASE_URL=http://localhost:8080 \
  python -m sync --type anime --limit 100
```

| 观察项 | 结果 |
| --- | --- |
| 首次入库 | `抓取 100，通过校验 100，拒绝 0，批次 1（已送达 1）`，`inserted=100` |
| 重跑同一命令 | `inserted=0, unchanged=100`，作品数停在 103（另 3 条是 `samples/` 的样本） |
| `batch_id` 复用 | 两轮都是 `otaku_site-anime-20261020-7f234f643ed7`，说明 Python 的幂等键确实按 source_id 集合生成 |
| 服务端日志 | 全程 0 条 WARN / ERROR |
| 读接口 | 列表 103 条 / 21 页，`q=高达` 命中 4 条真实作品，分页翻满 11 页无重复无遗漏 |
| 详情 | 10 字段齐全，`summary` 1436 字（`【时代背景】`后保留 `\n`），`updated_at` 为带 `Z` 的 RFC 3339 |
| 封面 | 真实回源 `image/webp` 110KB，`ETag` + `Cache-Control: max-age=2592000`，带 `If-None-Match` 返回 `304` |
| 数据分布 | 评分 7.2–9.2；103 条中仅 2 条无标签（都来自 `samples/`），说明真实来源的标签填充率比文档中的抽样更高 |

> 上一轮 `batch_id` 幂等的设计判断在这里得到验证：两轮同一个 `batch_id`，服务端返回的是**本次真实处理结果**
> （`inserted=100` → `unchanged=100`），而不是回放首轮结果。若按 openapi 原文字面短路，第二轮会返回
> `inserted=100`，D2 直接误判。

## 多来源兼容性（bangumi）

`sync-python` 的 `feat/bangumi-archive-source` 分支会提交 `source=bangumi` 的记录（该分支内附有一份
`backend-java/bangumi-source-notes.md`，列了 4 个需要后端配合的点）。当前实现已兼容，并逐条实测：

| 提醒项 | 本实现的处理 | 实测结果 |
| --- | --- | --- |
| `source` 需可扩展 | 只校验非空与 ≤64 字符，**不设白名单** | `source=bangumi` 正常入库，`inserted=4`、0 rejected |
| `cover_url` 恒为 null | 存 SQL NULL，出参 null，封面端点 404，不回源 | 详情 `cover_url=null`；`/api/covers/{id}` → 404 |
| `tags` 的 `[]` 与 `null` 必须区分 | `TagsJson` 保留三态：`[]` 清空、`null` 不覆盖 | 传 `null` → `unchanged` 且旧标签保留；传 `[]` → `updated` 且标签变 `[]` |
| 评分对象内 `source` 不设白名单 | 原样保存 `rating.source` | 入库 `rating_source=bangumi`，详情原样返回 |
| 同号不同源是两个作品 | 唯一键 `(source, source_id)` | `source_id=70` 在 `otaku_site`／`bangumi` 下是两条，`work_id` 不同 |

> 仍待团队处理：`docs/openapi.yaml` 里 `source` 还是 `enum: [otaku_site]`，需要把枚举放开
> （Python 侧已在提醒中提出）。代码侧不受影响，但文档不改会让联调的人以为 `bangumi` 会被拒。

## 阶段 2：账号与个人数据

实现口径以 [`docs/stage2-account-collection-contract.md`](../docs/stage2-account-collection-contract.md) 为准
（该文档仍为 DRAFT，§11 的 3 / 4 / 8 属 Java 决定项，本实现按推荐值落地：不透明令牌、LWW、生产必须 HTTPS）。

设计要点：

- **认证**：`Authorization: Bearer <43 字符不透明令牌>`，30 天固定有效期、不滑动续期；库里只存 `SHA-256(token)`，口令用 BCrypt(cost 10)。
- **多设备**：一次登录一行 `user_session`，退出只撤销当前这一行——一端登录或退出都不影响另一端（C1/C9）。
- **不开放自助注册**：账号走 `POST /internal/accounts`（`X-Internal-Token`），对应契约 §11.7 与附录 A。
- **收藏三态**：`null` = 未收藏（记录不存在）；`status=null` = 已收藏但未设状态；`[]`… 无此概念，取消收藏直接删行（C4）。
- **PUT 与 PATCH 分工**：`PUT` 是 upsert（可创建），`PATCH` 只改不建、记录不存在返回 409 —— 这是 C11 成立的唯一方式。
- **写接口只收目标状态**，不提供 toggle，避免重试把用户操作反转。
- **越权防护**：所有个人数据查询都强制 `user_id = 当前会话`，路径与参数里都不出现 `user_id`（C5）。
- **logout 幂等**：已失效或无令牌调用也返回 204，退出流程不会卡在 401 分支上（契约 §4.3）。

已用脚本逐条对照契约验证 **35 项全通过**，覆盖 C1–C5、C9–C11、错误码、幂等与三态语义：
两端并存、跨端可见、未收藏返回 200（不是 404）、`status=none` 过滤、取消后另一端消失、
409 `COLLECTION_REQUIRED`、被退出令牌 401、重复 logout 仍 204。

已知未做（不隐瞒，避免文档比实现好看）：

- **登录失败限流**：契约 §4.1 建议「同账号 5 次 / 15 分钟 → 429 `RATE_LIMITED`」，当前未实现，
  因此 `openapi.yaml` 里也没有声明 429。
- **过期会话清理**：只按 `expires_at` 过滤，没有定时清理任务，`user_session` 会缓慢增长。
- **`trace_id`**：错误信封保持阶段 1 形状，未加 trace_id。

## 技术选型

| 项 | 选择 | 理由 |
| --- | --- | --- |
| 框架 | Spring Boot 3.5.16 + JDK 17 | 本机 JDK 17；3.5 是 3.x 最新维护线，API 与 Jackson 2 稳定，团队上手成本低 |
| 构建 | Maven Wrapper（`mvnw`/`mvnw.cmd`） | 本机没有 mvn/gradle，Wrapper 让任何人 clone 即构建 |
| 持久层 | Spring JDBC（`NamedParameterJdbcTemplate`） | 场景就是纯 SQL：`null` 不覆盖在 service 里做"合并后整行 UPDATE"，不需要动态 SQL 或 ORM。读写都收敛在 `*Repository`，日后换 MyBatis 只动这一层 |
| 迁移 | Flyway | 表结构进版本库，谁的环境都能一键对齐 |
| 时间 | 库内 UTC `DATETIME(3)`，出参 `Instant` | 契约要求 RFC 3339；避免服务器时区影响排序与比较 |

## 快速开始

### 1. 起数据库（两种方式，任选其一）

**方式 A：Docker Compose（推荐）**

```powershell
cd backend-java
docker compose up -d
docker compose ps          # 等到 STATUS 变成 healthy（首次约 20–40 秒）
```

- 镜像 `mysql:8.0`，宿主端口 **3307 → 容器 3306**（默认不占 3306，避免和本机已有的 MySQL 冲突）
- 自动建库 `otaku`，账号 `otaku / otaku123`，字符集 `utf8mb4_0900_ai_ci`，时区 UTC
- 数据在命名卷 `otaku-backend_mysql-data` 里：`docker compose down` 不丢，`docker compose down -v` 才清空
- 拉不动 Docker Hub 时用镜像站覆盖：`$env:MYSQL_IMAGE="docker.m.daocloud.io/library/mysql:8.0"; docker compose up -d`
- 想用网页版看数据：`docker compose --profile tools up -d` → http://localhost:8081

**方式 B：用本机已装的 MySQL**

```bash
mysql -u root -p < src/main/resources/db/manual/00-create-database.sql
```

两种方式都不用手动建表：Flyway 启动时自动执行 `src/main/resources/db/migration/V1__init.sql`。

### 2. 启动后端

**配方式 A（Docker）——一条命令**，`local` profile 已经把端口、账号、开发令牌都配好：

```powershell
$env:SPRING_PROFILES_ACTIVE = "local"
.\mvnw.cmd spring-boot:run
```

```bash
# macOS / Linux / Git Bash
SPRING_PROFILES_ACTIVE=local ./mvnw spring-boot:run
```

**配方式 B（本机 MySQL）——显式给参数**：

```powershell
$env:DB_USER="root"; $env:DB_PASSWORD="<你的密码>"; $env:OTAKU_INTERNAL_TOKEN="dev-token"
.\mvnw.cmd spring-boot:run
```

> `application-local.yml` 里的口令与 `dev-token` **只用于本机联调**，任何共享/线上环境都不要激活 `local` profile。

### 3. 配置项

| 变量 | 必填 | 说明 |
| --- | --- | --- |
| `OTAKU_INTERNAL_TOKEN` | **是** | 内部导入令牌，与 Python 侧 `OTAKU_INTERNAL_TOKEN` 必须是同一个值。为空则 `/internal/**` 全部 401 |
| `DB_USER` / `DB_PASSWORD` | 是 | 默认 `root` / 空 |
| `DB_HOST` / `DB_PORT` / `DB_NAME` | 否 | 默认 `localhost` / `3306` / `otaku`（用 `local` profile 时端口默认 3307） |
| `SPRING_PROFILES_ACTIVE` | 否 | 设为 `local` 即套用容器配套的数据库与开发令牌 |
| `MYSQL_PORT` / `MYSQL_IMAGE` | 否 | 只影响 `compose.yaml`：宿主端口（默认 3307）与镜像地址 |
| `OTAKU_PUBLIC_BASE_URL` | 否 | 封面地址前缀。**留空按请求 host 推导**，这样模拟器 `10.0.2.2`、桌面 `127.0.0.1`、真机局域网 IP 都不用改配置 |
| `OTAKU_COVER_CACHE_DIR` | 否 | 默认 `./data/covers` |

健康检查：`curl http://localhost:8080/actuator/health`

## 接口清单

| 接口 | 方法与路径 | 鉴权 | 说明 |
| --- | --- | --- | --- |
| ② 提交批次 | `POST /internal/import/batches` | `X-Internal-Token` | 单批 ≤500 条，逐条返回四类计数与失败明细 |
| ②b 查批次 | `GET /internal/import/batches/{batch_id}` | `X-Internal-Token` | 重跑前核对用 |
| ③ 列表 | `GET /api/works?type=&q=&page=&page_size=` | 无 | 6 字段，**不含 summary**；`page_size` 上限 50 自动截断 |
| ④ 详情 | `GET /api/works/{work_id}` | 无 | 10 字段；不存在或格式非法都是 404 |
| ⑤ 封面 | `GET /api/covers/{work_id}` | 无 | 代理 + 本地缓存，30 天缓存 + ETag；无封面/回源失败返回 404 |

**阶段 2（账号与个人数据）**——字段与语义以
[`docs/stage2-account-collection-contract.md`](../docs/stage2-account-collection-contract.md) 为准：

| 接口 | 方法与路径 | 鉴权 | 说明 |
| --- | --- | --- | --- |
| 建号（内部） | `POST /internal/accounts` | `X-Internal-Token` | 首期不开放自助注册；带 `username` / `password` |
| 登录 | `POST /api/auth/login` | 无 | 每次登录新建会话，**不踢掉其他设备** |
| 当前用户 | `GET /api/auth/me` | Bearer | `user_id` / `username` / `display_name`（首期恒为 null） |
| 退出 | `POST /api/auth/logout` | 可选 | 只撤销当前令牌；**已失效或无令牌也 204** |
| 收藏列表 | `GET /api/me/collections?status=&page=&page_size=` | Bearer | `status` 可传 `want`/`watching`/`watched`/`none`；排序 `updated_at DESC, work_id ASC` |
| 单条状态 | `GET /api/me/collections/{work_id}` | Bearer | **未收藏也是 200**，用 `collected=false` 表示；作品不存在才 404 |
| 加入收藏 | `PUT /api/me/collections/{work_id}` | Bearer | upsert，幂等；`status` 可省略 |
| 改状态 | `PATCH /api/me/collections/{work_id}` | Bearer | 只改不建；记录不存在 → 409 `COLLECTION_REQUIRED` |
| 取消收藏 | `DELETE /api/me/collections/{work_id}` | Bearer | 删整条记录，状态随之消失；幂等 204 |

### 冒烟测试

```bash
TOKEN=dev-token-please-change

# 先不带令牌，应当 401 UNAUTHORIZED
curl -i -X POST http://localhost:8080/internal/import/batches \
  -H "Content-Type: application/json" \
  -d @samples/import-batch-sample.json

# 正常导入 → inserted=3
curl -s -X POST http://localhost:8080/internal/import/batches \
  -H "Content-Type: application/json" -H "X-Internal-Token: $TOKEN" \
  -d @samples/import-batch-sample.json

# 再发一次同一批 → inserted=0, unchanged=3（验收 D2）
curl -s -X POST http://localhost:8080/internal/import/batches \
  -H "Content-Type: application/json" -H "X-Internal-Token: $TOKEN" \
  -d @samples/import-batch-sample.json

# 边界用例 → 4 条 rejected + 1 条 DUPLICATE_IN_BATCH 提示
curl -s -X POST http://localhost:8080/internal/import/batches \
  -H "Content-Type: application/json" -H "X-Internal-Token: $TOKEN" \
  -d @samples/import-batch-edge-cases.json

# 列表（page_size 传 100 应被截断为 50）
curl -s "http://localhost:8080/api/works?page=1&page_size=100"
curl -s "http://localhost:8080/api/works?q=%E9%AD%94%E6%B3%95&type=anime"
curl -s "http://localhost:8080/api/works?type=movie"          # 400 BAD_REQUEST
curl -s -i "http://localhost:8080/api/works/no-such-id"       # 404 WORK_NOT_FOUND
```

> Windows 控制台注意：URL 里的中文必须百分号编码，直接写 `q=魔法` 会让 Tomcat 返回 400
> （Flutter 的 Dio 会自动编码，所以只有手工 curl 才会踩到）。
> 上面 `q=%E9%AD%94%E6%B3%95` 就是"魔法"的 UTF-8 百分号编码。

## 目录结构

```text
backend-java/
  pom.xml                 Spring Boot 3.5.16 / JDK 17
  mvnw, mvnw.cmd          Maven Wrapper（无需安装 Maven）
  compose.yaml            本地 MySQL 8.0 容器（:3307，含可选 Adminer）
  samples/                可直接用于 curl 的请求体（含边界用例）
  src/main/java/com/otaku/
    common/               错误码、统一信封、分页、LIKE 转义、ID 与令牌生成
    config/               应用配置、内部令牌过滤器、CORS、对外地址解析
    work/                 接口③④：Repository / Service / Controller + DTO
    importer/             接口②：校验、合并规则、批次记录
    cover/                ⑤ 封面代理与本地缓存
    user/                 阶段 2：账号持久化
    session/              阶段 2：多设备会话（只存令牌摘要）
    account/              阶段 2：内部建号接口（/internal/accounts）
    auth/                 阶段 2：注册/登录/退出 + Bearer 鉴权过滤器
    collection/           阶段 2：收藏与观看状态
  src/main/resources/
    application.yml
    db/migration/         Flyway 迁移（V1 作品、V2 账号与会话）
    db/manual/            建库语句（手动执行一次，Flyway 不管）
  src/test/java/          合并规则、条目校验、LIKE 转义、ID/令牌、JSON 形状的单元测试
```

## 几条容易踩的实现约定

1. **`batch_id` 不做短路回放**。Python 的 `batch_id` 只哈希 `source_id` 集合（`sync-python/src/sync/pipeline.py:30-45`），不含字段内容——同一天改了评分重跑会得到同一个 `batch_id`。若按 openapi.yaml 那句"返回首次结果"短路，验收 D3 会永远不生效且无任何报错。因此每次真实 upsert，幂等由 `uk_work_source` 唯一约束保证；`import_batch.request_hash` 用于识别"同 ID 不同内容"并打 warn。
2. **`updated_at` 只在内容真的变化时推进**，否则 D2 的 `unchanged` 会变成 `updated`。
3. **条目校验必须手写**，不能把 `@Valid` 打在 `items` 列表上——那样一条坏数据会让整批 400，违反"单条 rejected 不拖垮整批"。
4. **封面地址不存库**：出参时按当前请求 host 拼，换联调环境不用刷表。来源地址单独存 `cover_source_url`。
5. **`q` 做了通配符转义**：`%` `_` `!` 都按普通字符匹配，避免用户输入变成通配查询。
6. **`tags` 读库时必须规范化**：MySQL 的 JSON 列会把 `["a","b"]` 读成 `["a", "b"]`，直接字符串比较会导致
   每次重跑都判定"变了"。统一走 `TagsJson.canonical()`，并有 `TagsJsonTest` 兜住这条回归。
7. **运行时会生成 `data/covers/` 封面缓存目录**（已 gitignore）。删掉不影响正确性，只会重新回源。

## 与契约的偏差（需回写 docs，见 Issues 待确认）

| 项 | 现状 | 说明 |
| --- | --- | --- |
| 封面端点 | 本模块自定义 `GET /api/covers/{work_id}` | 契约要求代理但 `openapi.yaml` 无此端点，需三人确认后补进文档 |
| 错误码 `BATCH_NOT_FOUND` | 新增 | 契约 404 只定义了 `WORK_NOT_FOUND`，批次查询需要区分 |
| 逐条码 `SOURCE_ID_REQUIRED` | 新增 | Python 的 `validate()` 不校验 `source_id` 为空，必须由 Java 拒收 |
| 逐条码 `TITLE_TOO_LONG` | 新增 | 契约要求 title 不截断且上限 500，超长只能整条拒收 |
| `source` 取值 | 只校验非空与长度，不强制 `otaku_site` | 便于后续加站点；非法值会打 info 日志 |

## 约定

- 接口契约与数据契约以 `docs/` 中经三人确认的文档为准，未确认前不视为已生效。
- 面向客户端的接口需同时满足手机端与桌面端的调用方式。
- 接口与字段以 [`../docs/stage1-minimal-contract.md`](../docs/stage1-minimal-contract.md) 为准（第一阶段）；更完整的范围、阶段划分与验收步骤见 [`../docs/otaku-project-plan-v2.md`](../docs/otaku-project-plan-v2.md) 与 [`../docs/acceptance.md`](../docs/acceptance.md)。

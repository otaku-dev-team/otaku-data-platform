# 站主运营后台 · 使用说明（首版）

> **状态**：首版已实现（2026-10-27），二期（站主名单自助维护、用户详情与收藏）同日补齐。对应 **Issue #144**，设计依据
> [`site-owner-console-proposal.md`](site-owner-console-proposal.md)（§2 范围、§3 权限、§4 边界、§8 拍板）。
> 接口形状见 [`openapi.yaml`](openapi.yaml) 的「站主后台」与「内部站点」两段。
>
> 本文写给两种人：**站主**（怎么用、能做什么、不能做什么）与**平台运维**（怎么开通、怎么排查）。

---

## 1. 它是什么

站主自助管理入口。首版只做三件事（提案 §2.1）：

| 能力 | 站主能做什么 | 接口 |
|---|---|---|
| 数据概览 | 看本站作品数、按类型分布、字段覆盖率、同步摘要 | `GET /api/console/overview` |
| 用户管理 | 看本站客户端用户列表、**禁用/解禁** | `GET /api/console/users`、`POST .../{user_id}/disable|enable` |
| 同步状态 | 看最近一次同步时间与成败、近期运行明细、失败条目 | `GET /api/console/sync` |
| 站主名单（二期） | 看/加/停/恢复**本站**站主，改自己的口令 | `GET|POST /api/console/admins`、`POST .../{admin_id}/disable|enable`、`POST /api/console/auth/password` |
| 用户详情与收藏（二期） | 看单个用户的状态、会话数、收藏聚合与明细 | `GET /api/console/users/{user_id}`、`GET .../collections` |

页面：`http://<后端地址>/console/`（同源静态页，零构建、无 CDN）。

---

## 2. 站主**不能**做什么（红线，不是"暂时没做"）

| 不做 | 为什么 |
|---|---|
| 站点接入、站点配置 | 属于底座核心能力。开放给站主，网站就能自行接入任意站点，服务价值归零（提案 §2.2） |
| 把「站主名单」当成站点配置 | 两者不同：名单只决定**谁有本站的登录权**，不能接入新站点、不能改来源绑定。二期允许站主自助增删名单（提案 §8 第 3 条），但 `/internal/sites` 仍然只有平台能调 |
| 跨站查看/管理 | 站主只能看自己这一个站点 |
| 底座管理 | 平台自身与其他站点的接入配置，不向站主暴露 |
| 改网站侧账号 | 平台不回写网站账号状态（提案 §4.2） |
| 触发同步 | 手动触发属二期（提案 §9）。后台能触发就等于给了站主一个能打满来源站的按钮 |

**这些不是靠"界面上没放按钮"保证的，而是代码里没有对应的写入口**：

- 站主能走到的路径只有 `ConsoleAuthFilter` 放行的 `/api/console/**`；
- 建站与开设站主只在 `/internal/**`（`X-Internal-Token`，令牌只在平台侧），后台页面没有任何调用点；
- `ConsoleRoutesTest` 把后台接口清单钉成白名单：**多一条就红**，新增接口必须显式改清单。

---

## 3. 「禁用」到底禁了什么（最容易误解的一条）

**禁用 = 禁止这个用户登录本站客户端，并当场撤销他已登录的设备。**
**它不会封掉他在网站上的账号。**

理由（提案 §4.2 已拍板）：网站账号的存废是网站自己的事；平台不回写网站业务数据，且"站主禁用"不等于"用户本人授权"。

落地成两件事，缺一不可：

1. `app_user.status = 'disabled'` → 之后的登录返回 `403 USER_DISABLED`；
2. 撤销该用户**全部**平台会话 → 已经登录的设备立刻掉线，不用等 30 天有效期。

后台页面在用户页顶部常驻这句提示，禁用成功的响应里也带同一句（`note` 字段），前端**原样展示**。
写在文档里不够——前端换个实现就会漏掉，而站主会误以为自己拿到了网站账号的生杀大权。

> 若站主真要"封掉网站账号"，那是网站后台的能力。我们不做，也不该做。

---

## 4. 数据隔离怎么保证

| 机制 | 落点 |
|---|---|
| 站点身份只来自登录态 | `ConsolePrincipal`（由 `ConsoleAuthFilter` 写入请求属性）。**所有请求体与 query 里都没有 `site_key`** |
| 可见范围只在一处推导 | `ConsoleScopeResolver` → 站点 + `site_source` 绑定的来源；其它查询一律吃这个范围 |
| 每条 SQL 都带站点条件 | 用户查询 `where u.site_key = ?`；作品/同步按 `source in (...)` |
| 未配来源 = 看不到 | 不会退化成"不加过滤看全库"（多站点后台最典型的越权入口） |
| 越权 → 403 | 与"不存在"（404）分开：前者该找平台要权限，后者该检查账号 |

站主之间互不可见靠的是 `site_source.uk_site_source`：**一个 `source` 只能属于一个站点**。
允许共用的话，A 站的作品会同时出现在 B 站后台，任何 where 都说不清。

集成测试 `ConsoleIsolationIntegrationTest`（真 MySQL + 完整过滤器链）覆盖：
跨站禁用 403、列表只含本站、未归属账号不可见且不可禁、概览与同步按来源过滤、禁用后旧令牌失效且重登 403、两套令牌互不通用；
二期补充：站主名单只含本站（`self` 标记）、跨站停用站主 403、不能停用自己、用户详情/收藏跨站 403、
收藏按状态过滤与分页、改口令后其它设备会话失效、审计留痕。

---

## 5. 平台运维：怎么开通一个站主

三步，全部在平台侧（`X-Internal-Token`）。**没有后台界面**——这是刻意的。

```bash
BASE=http://127.0.0.1:8080
TOKEN=$OTAKU_INTERNAL_TOKEN

# 1) 建站 + 绑定来源（source 与 work.source 同值；一个来源只能属于一个站）
curl -s -X POST "$BASE/internal/sites" -H "X-Internal-Token: $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"site_key":"<站点键>","display_name":"<展示名>","sources":["<来源标识>"]}'

# 2) 开设站主（加入站主名单）
curl -s -X POST "$BASE/internal/site-admins" -H "X-Internal-Token: $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"site_key":"<站点键>","username":"<登录名>","password":"<8-72位>","display_name":"<称呼>"}'

# 3) 客户端账号要能被这个站点管，建号时带 site_key
curl -s -X POST "$BASE/internal/accounts" -H "X-Internal-Token: $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"username":"alice","password":"........","site_key":"<站点键>"}'
```

### 5.1 历史账号为什么可能看不到

V10 迁移给 `app_user` 加了可空的 `site_key`。**迁移之前的账号都是 NULL**：

- 它们能正常登录客户端；
- 但**任何站主后台都看不到、也禁不了**（fail-closed）。

需要让某个站点管到它，必须由平台侧显式补归属：

```sql
UPDATE app_user SET site_key = '<站点键>' WHERE user_id IN ('U-...', 'U-...');
```

刻意不做"默认归属首个站点"：猜错站点意味着 A 站能把 B 站的用户封掉。

### 5.2 停用站主 / 停用站点

四个内部接口（`X-Internal-Token`），全部幂等——重复调用不报错，返回里 `revoked_*` 为 0：

```bash
BASE=http://127.0.0.1:8080
TOKEN=$OTAKU_INTERNAL_TOKEN

# 停用站主：登录与已发令牌立即 403（并撤销其全部后台会话，已登录的浏览器当场掉线）
curl -s -X POST "$BASE/internal/site-admins/<admin_id>/disable" -H "X-Internal-Token: $TOKEN"

# 恢复站主（会话不恢复，需重新登录）
curl -s -X POST "$BASE/internal/site-admins/<admin_id>/enable" -H "X-Internal-Token: $TOKEN"

# 停用站点：该站**全部**站主立即 403（撤销该站所有站主会话）；客户端数据原样保留
curl -s -X POST "$BASE/internal/sites/<站点键>/disable" -H "X-Internal-Token: $TOKEN"

# 恢复站点
curl -s -X POST "$BASE/internal/sites/<站点键>/enable" -H "X-Internal-Token: $TOKEN"
```

语义与站主禁用用户（§3）完全同构：**改状态 + 撤会话**，两条腿缺一不可。

| 要点 | 说明 |
|---|---|
| 404 分流 | 站点不存在 → `SITE_NOT_FOUND`；站主不存在 → `ADMIN_NOT_FOUND`；与幂等重试（200）分开 |
| 站点状态值 | `active / suspended`（`site.status`）；站主为 `active / disabled`（`site_admin.status`） |
| 停用期间 | 停用的站点**不能再加站主**（400）；恢复后才行 |
| 停用站主 ≠ 停用站点 | 四条接口刻意分开：站点停用影响该站所有站主，爆炸半径完全不同 |
| 审计 | 每次流转记一条日志（操作者、对象、撤销会话数）；审计表仍未做（§8） |

> 首版（#210）之前这里需要直接改 SQL；上面的接口在后续补齐，
> `ConsoleRoutesTest` 的 `/internal` 白名单已钉住这六条路径。


### 5.3 站主自助维护名单（二期）

站主可以自己加/停本站的同事，不需要找平台。**站点接入与配置仍然只在平台侧**。

```bash
BASE=http://127.0.0.1:8080
# 先登录拿后台令牌
TOKEN=$(curl -s -X POST "$BASE/api/console/auth/login" -H 'Content-Type: application/json' \
  -d '{"username":"<站主>","password":"<口令>"}' | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])')

# 看本站名单（self=true 是当前登录的这位）
curl -s "$BASE/api/console/admins" -H "Authorization: Bearer $TOKEN"

# 新增站主（初始口令由你设置，平台只存 BCrypt，响应不回显口令）
curl -s -X POST "$BASE/api/console/admins" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"username":"<登录名>","password":"<8-72位>","display_name":"<称呼>"}'

# 停用 / 恢复（不能停用自己；停用会立即撤销对方的后台会话）
curl -s -X POST "$BASE/api/console/admins/<admin_id>/disable" -H "Authorization: Bearer $TOKEN"
curl -s -X POST "$BASE/api/console/admins/<admin_id>/enable"  -H "Authorization: Bearer $TOKEN"
```

| 规则 | 行为 |
|---|---|
| 不能停用自己 | `400`——手滑就再也进不来，只能找平台 |
| 目标是别站的站主 | `403 FORBIDDEN`（不存在是 `404 ADMIN_NOT_FOUND`） |
| 登录名重复 | `409 USERNAME_TAKEN`（站主登录名**全局唯一**，登录时不用先选站点） |
| 停用 ≠ 删号 | 改状态 + 撤会话；恢复后对方重新登录即可 |

### 5.4 修改自己的口令

```bash
curl -s -X POST "$BASE/api/console/auth/password" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"old_password":"<旧>","new_password":"<新，8-72位>"}'
# 204；其它设备上的后台会话会被撤销，当前设备保留
```

> 之所以现在就做：二期允许站主自建账号，若没有改密入口，初始口令只能长期在聊天工具里流转。

---

## 6. 站主登录方式：现在是过渡态

| 阶段 | 方式 | 状态 |
|---|---|---|
| 现在 | **平台建号**（`/internal/site-admins`）+ 站主名单校验 | ✅ 已实现 |
| 网站 OAuth（#147）就绪后 | 网站账号登录 + 名单校验（提案 §4.1 方案 B） | 表结构已预留 |

预留方式是 `site_admin.identity_source` + `external_user_id`：
接入后新增 `identity_source='site_oauth'` 的行、`password_hash` 留空，登录改走站点授权。
**后台接口与页面不需要改**——这也是当初选 B 而不是另建一套账号的理由。

---

## 7. 安全与运维要点

| 项 | 取值 | 理由 |
|---|---|---|
| 后台会话有效期 | **12 小时**，不滑动续期 | 管理权限不该"用着用着一直有效"；客户端是 30 天，两者刻意不同 |
| 令牌存储 | 服务端只存 SHA-256；浏览器放 `sessionStorage` | 泄库不能直接冒用；关标签即失效，不落磁盘、不进 URL |
| 两套凭据 | 客户端 `bearerAuth` 与后台 `consoleAuth` 互不通用 | 一个令牌泄露不会顺带打开另一面（有测试） |
| CORS | **不对 `/api/console/**` 开放** | 后台页面同源加载；管理接口对任意源开放只会扩大攻击面 |
| 登录失败限流 | 复用 `LoginThrottle`，5 次 / 15 分钟 | 与客户端同一套策略 |
| 停用的站主/站点 | 返回 **403** 并说明原因 | 返回 401 会让站主以为是掉线，反复登录撞同一堵墙 |
| 审计 | `console_audit` 记录名单变更与用户禁用/解禁 | 提案 §4.3 要求「有据可查」；只写不改，平台侧查库/导出 |

### 7.1 排障对照

| 现象 | 多半是 |
|---|---|
| 登录 403「站点已停用」 | `site.status != 'active'` |
| 登录 403「站主账号已停用」 | `site_admin.status != 'active'` |
| 概览全是 0、同步显示「从未同步」 | 站点没绑 `site_source`，或绑的 source 与 `work.source` 不一致 |
| 用户列表空 | 账号的 `site_key` 为空或不等于本站（见 §5.1） |
| 禁用后用户仍能进网站 | 正常：禁用只作用在客户端（§3） |

---

## 8. 已知未做（当前范围外）

- 站主「邀请链接 / 邀请码」流程：二期采用**直接建号 + 线下转告初始口令**；
  站点侧管理员邀请码属于网站能力，不在我们这里做；
- 手动触发同步 / 按 `source_id` 一键补齐（见 §2）；
- 内容层面的运营能力（改作品、下架等）：数据是来源站快照、只读取数（铁律 1），不做；
- 审计的**后台读接口**：表已建、写入已接（§7），查看走平台侧查库/导出；
- ~~停用站主/站点的内部接口~~：已补齐，见 §5.2；
- ~~站主自助增减名单~~：已补齐，见 §5.3；
- ~~用户详情与收藏~~：已补齐，见 §1 表格与 `GET /api/console/users/{user_id}`。

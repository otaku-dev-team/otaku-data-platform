# 阶段 2 账号绑定联调契约（草案）

> 状态：**草案，待三人确认**（zm + @pyxz0 + @riceyu02）。本文触及账号数据结构（红线 1），确认通过后才进 `openapi.yaml` 与实现；未确认前只作为文档级设计存在。
> 上游依据：[`product-positioning.md`](product-positioning.md) §4（身份归属）/ §6.3（字段预留）；站点定稿契约与联调配置见 [`identity-auth-endpoint-playbook.md`](identity-auth-endpoint-playbook.md) §2 / §4.1–§4.3。
> 作者：zm（契约主责）｜日期：2026-10-24

## 0. 一句话

站点 OAuth 授权码已定稿、联调配置到手；平台侧按「后端令牌交换代理」对接，用户表预留身份映射字段，本期做到**用网站账号登录客户端**；收藏写权限等二期 scope。

## 1. 站点侧契约（已定稿，全部就位）

四端点与安全边界（详见 playbook §2 / §4.1）：

| 端点 | 形态 | 要点 |
| --- | --- | --- |
| `GET /oauth/authorize?client_id&redirect_uri&state` | 浏览器打开 | 未登录先走站点登录页；登录后自动回跳 `redirect_uri?ticket&state`；redirect_uri 白名单制、state 必填（防 CSRF） |
| `POST /api/auth/token` | `x-www-form-urlencoded` | 入参 ticket + client_id + client_secret；出参 `access_token`（Bearer，3600s）+ `user{external_user_id, nickname, avatar_url}` |
| `GET /api/me` | Bearer | `external_user_id` / `nickname` / `avatar_url` / `scope:"identity"` |
| `POST /api/auth/revoke` | 持有效 Bearer（self-revoke）或站点管理员会话 | 持 Bearer 方撤销该持有者名下、同 client 的全部未吊销令牌；管理员侧可按 token 或 external_user_id 全量吊销 |

三点站点侧决定（已接受并拍板，playbook §4.1 / PR #141）：`client_secret` 加固（防票据冒领）、无用户同意页（站点单方面授权）、撤销入口归站点（self-revoke 已开放并拍板启用）。

续期（站点二次回复确认）：不提供 refresh_token；`/oauth/authorize` 对已登录用户**幂等**——过期前静默重走授权即可，用户无感知，成本是一次浏览器跳转。

联调配置（站点分配，2026-10-24；完整管理细则见 playbook §4.3）：

| 项 | 值 | 状态 |
| --- | --- | --- |
| `client_id` | `otaku-app-client` | ✅ 站点分配，以站点白名单为准 |
| `client_secret` | 联调临时值 | ✅ 已获取；**只存服务端环境变量 `OTAKU_SITE_OAUTH_CLIENT_SECRET`，绝不入库、不进任何仓库文件与文档**；正式上线前必须替换为高强度随机值并单独注入目标服务器（站点警示：不要沿用临时 secret） |
| `redirect_uri` 白名单 | `com.otaku.app:/oauth2redirect`（移动端自定义 scheme，Android / iOS） | ✅ 已入白名单 |
| 桌面端 loopback | `http://127.0.0.1:38711/callback` | ✅ **已入站点白名单（2026-10-28 上线）**；本轮桌面入口隐藏、不阻塞联调启动 |
| 票据 / 令牌有效期 | 120 秒（一次性）/ 3600 秒 | ✅ |

### 1.1 联调前置实测核对（2026-10-24，只读探测）

> 目的：联调前把「契约写的样子」与「站点真实返回」对齐，避免 @pyxz0 / @riceyu02 照文档实现后才发现漂移。方式=读站点 `openapi.json`（138 路径）+ 无凭据 / 假值探测；**未使用真实 secret、未登录任何账号**。

**端点存在性**：四个端点均已在站点 `openapi.json` 中登记——`GET /oauth/authorize`、`POST /api/auth/token`、`GET /api/me`、`POST /api/auth/revoke`。

**实测行为**

| 探测 | 实际结果 | 结论 |
| --- | --- | --- |
| `GET /oauth/authorize`（无参数） | `400` | 参数校验存在 |
| `GET /oauth/authorize?client_id=otaku-app-client&redirect_uri=com.otaku.app:/oauth2redirect&state=probe` | `303` → `/login?next=...` | client_id 有效、redirect_uri 接受、**未登录先跳登录页**（无同意页）；客户端跟随系统浏览器即可，不解析此跳转 |
| 同上但 `client_id=nope` | `400` | 非法 client 被拒 |
| `GET /api/me`（无 Bearer） | `401 {"detail":"missing_token"}` | 缺令牌的错误码 |
| `POST /api/auth/token`（假 ticket + 假 secret） | `401 {"detail":"invalid_client"}` | **secret 先于 ticket 校验**（防票据冒领）；平台侧「secret 错」应映射到此 |
| `POST /api/auth/revoke`（无 Bearer） | `403 {"detail":"forbidden"}` | 需持有有效 Bearer |

**请求体字段（站点 openapi 精确，名与类型以此为准）**
- `POST /api/auth/token`（`x-www-form-urlencoded`）：`client_id`、`client_secret`、`ticket`（**无** `grant_type` / `response_type`）。
- `POST /api/auth/revoke`（`x-www-form-urlencoded` + `Authorization` header）：`access_token`、`external_user_id`（按需取其一或并用）；与「按 token 或 external_user_id 全量吊销」一致。
- `GET /oauth/authorize`（query）：`client_id`、`redirect_uri`、`state`（**无** `response_type`）。

**需在实现层注意的差异**
1. **错误信封不同**：站点是 FastAPI 的 `{"detail": "..."}`（422 为 `{"detail":[...]}`），平台是 `{code,message}`。平台后端必须捕获并**归一成平台错误码**，不得把站点 `detail` 原文透传给客户端（避免泄漏上游细节，也保证客户端只认平台错误契约）。
2. 站点 openapi 的 `securitySchemes` 为空（用 `Authorization` header 参数表达），属文档层面缺声明，**不影响行为**；实现以实际 header 为准。
3. token 表单字段在 schema 层均为可选（默认空串），缺失由应用层报错；平台侧仍须做非空校验后再转发。
4. `authorize` 未登录返回 **303**（非 302）；桌面 loopback 补白前，联调先走移动端自定义 scheme。

**尚未验证（留待第 1 步联调）**：`token` 成功响应体字段（`access_token` / `user{external_user_id,nickname,avatar_url}`）与 `/api/me` 成功体、`revoke` 成功体——这些需真实授权 ticket，openapi 未标注类型，本次只读探测拿不到，按 §1 契约在第 1 步用真实 ticket 验证。

**结论**：契约（§1）与站点真实行为一致，具备联调条件；唯一遗留仍是桌面 loopback 端口补报。

## 2. 平台侧对接形态：令牌交换代理

站点要求 `client_secret`「仅你们后端持有、永不进浏览器」。App 与浏览器同属公开侧——secret 进 App 等于公开。因此平台侧只有一种正确形态：**平台后端做令牌交换代理**。

流程：

1. 客户端：用户点「用 Otaku 账号登录」→ **系统浏览器**打开 `/oauth/authorize?client_id=otaku-app-client&redirect_uri=com.otaku.app:/oauth2redirect&state=<随机>`。用系统浏览器而非 App 内 WebView：用户能从地址栏确认域名（防钓鱼），App 侧不接触登录页（RFC 8252 对原生应用的推荐）；
2. 站点：未登录 → 登录页（密码只在这里输入，平台全程不见）；已登录 → 直接回跳 `com.otaku.app:/oauth2redirect?ticket=<一次性>&state=<原样>`；
3. 客户端：校验 state 一致 → 拿 ticket 调平台后端；
4. 平台后端：带 client_secret 调站点 `/api/auth/token` 换 access_token 与 user 信息 → 按 `external_user_id` 查/建账号映射 → 建平台会话 → 平台令牌返回客户端；
5. 客户端：此后只走平台 `/api/**`，体验与平台账号登录无差异。

**端点草案（待确认 #1）**：`POST /api/auth/site-login`，请求 `{ ticket }`，响应 `{ token, user }`（平台会话令牌 + 用户信息，与现有 `POST /api/auth/login` 响应结构对齐）。ticket 一次性 120 秒，平台后端不落 ticket；失败（ticket 过期 / state 不符 / secret 错）返回 401，客户端引导重走授权。

为什么不是「客户端直持站点令牌」：secret 无处存放（进 App 即公开）；且平台持可撤销令牌 + `external_user_id` 映射，正是定位 §4.4「过渡期必须留后路」要的账号映射锚。

## 3. 数据模型（红线 1，待确认 #2）

按定位 §6.3「用户表现在就预留身份源 + 外部用户 ID」——**用户表加列**，不动现有账号体系：

- `identity_source`（可空）：如 `otaku_site`；NULL = 平台账号（现状语义完全不变）；
- `external_user_id`（可空）：站点用户主键，与 `identity_source` 共同构成映射；
- 唯一键 `(identity_source, external_user_id)`。

令牌存储：**只存哈希**（与站点「令牌只存哈希」对齐——我们侧泄漏也不裸奔）。哈希列 `site_token_hash` + `site_token_expires_at` 随本期实现落表，或并入现有会话体系，由后端主责定（列入待确认 #2）。

## 4. 账号映射与收藏迁移（文档级设计，不实现）

playbook §6 要求「账号映射 + 收藏迁移：文档级设计先做（映射规则、冲突策略、回滚），不实现」——本节即该设计。

**映射规则**：`(identity_source, external_user_id)` 唯一；站点 `external_user_id` 稳定不变 = 映射锚（站点契约保证）。一个平台账号绑定一个站点身份（首站单站 1:1；多站形态属未来目标，不预留 N:M）。

**本期范围**：scope 固定 `identity`（只读资料），**收藏 / 状态读写是二期**（C4，需站点再次授权扩展 scope）。故本期**不做收藏迁移**，只做身份映射；客户端收藏继续走平台账号既有模型。

**冲突策略（二期预设计，现在写清、不实现）**：平台账号已有收藏 + 站点授权进来时，按 work_id 归一后 LWW 合并，冲突保留双方时间戳供用户可见；批量合并在登录时触发，拉取站点 `/me/favorites` 全量后与本地合并。

**回滚**：解绑（退出登录 / 断开连接）即丢弃绑定、回到平台账号态；平台侧账号与收藏数据不删除、不修改，重绑可恢复。

## 5. 登录流程与兜底

- 客户端登录页**双入口**：「平台账号登录」（保留，邀请码制站点规则下的过渡形态）+「用 Otaku 账号登录」（授权流程）。呈现方式属客户端模块决定（待确认 #3）。
- **三态账号控制**（playbook §7.9 已拍板）：① 退出登录 = 平台即时本地解绑（不等站点侧过期）；②「断开与网站的连接」= 本地解绑 + self-revoke 远程吊销（持当前 Bearer 调 `POST /api/auth/revoke`，撤销该持有者名下同 client 全部未吊销令牌）；③ 站点管理员应急吊销（按 token 或 external_user_id）。
- **401 兜底**：站点令牌失效 / 被撤 → 平台侧请求失败 401 → 客户端**先静默重走授权一次**（authorize 幂等、无同意页，用户无感知），再失败才引导重新登录。
- **续期**：令牌临期（< 5 分钟）静默重走 authorize 换新票据 → 新令牌，用户无感知。

## 6. 分步联调计划

| 步 | 内容 | 参与方 | 通过判据 |
| --- | --- | --- | --- |
| 1 | 联调环境打通：平台后端用临时 secret 走 token 换取 + `/api/me` | @pyxz0 + 站点 | 拿到 access_token 与 `user{external_user_id}` |
| 2 | ticket 交换全链：`POST /api/auth/site-login` 建会话 | @pyxz0 | 平台令牌可访问既有 `/api/**` |
| 3 | 客户端授权流程：系统浏览器 + scheme 回跳 + state 校验 | @riceyu02 | Android / iOS 真机授权登录成功 |
| 4 | 映射落库 + 三态解绑 | @pyxz0 + @riceyu02 | 重登映射恒定；解绑 / self-revoke 生效 |
| 5 | 联调验收：新用户授权即登录、已有平台账号绑定、401 兜底、续期无感 | 三方 | §5 口径全过 |

每步独立可回滚；任一步卡住都不影响线上现状（平台账号登录不受影响）。

## 7. 安全纪律

- `OTAKU_SITE_OAUTH_CLIENT_SECRET`：只存服务端环境变量；绝不入库、不进日志、不回显、不进任何客户端与文档（正式环境由站点注入，同样只从环境变量读）；
- 正式上线前替换联调临时 secret（站点警示：不要沿用临时值），替换走密钥纪律；
- 令牌只存哈希；票据不落库；
- `nickname` / `avatar_url` 仅客户端内展示，不回写、不再分发；
- `/api/me` 调用与令牌续期绑定，量级可控，不给站点增加压力；
- 桌面端 loopback 端口：客户端已定稿为 `http://127.0.0.1:38711/callback`（见 `w1-login-dual-entry.md` §2.6），**已于 2026-10-28 入站点白名单**；本轮桌面入口隐藏、不阻塞联调启动。

## 8. 待三人确认清单

1. **平台侧端点形态**：`POST /api/auth/site-login` 的请求 / 响应定义（§2）——@pyxz0；
2. **数据模型**：用户表加列方案与令牌哈希归属（§3：加列 vs 哈希列另置）——@pyxz0；
3. **登录页双入口呈现**（§5）——@riceyu02；
4. **本期不做收藏写权限**（scope 固定 identity，二期 C4）——三方知悉，无异议即过。

确认通过后：契约主责补 `openapi.yaml` 阶段 2 账号节（含 `POST /api/auth/site-login`），`how-we-serve-sites.md` §2.2.7 同步收尾，实现由各模块按 §6 步骤推进。

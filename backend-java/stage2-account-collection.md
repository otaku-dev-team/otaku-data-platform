# 阶段 2 接口提案：账号 / 多设备会话 / 收藏与观看状态

> 状态：**草案 · 已实现并自测通过，待 Flutter 负责人确认**
> 依据：`docs/otaku-project-plan-v2.md` 第 2.2 / 5.2 节、`docs/acceptance.md` 第 3 节（C1–C11）
> 说明：`docs/` 是共享文档，本提案先放在模块目录；确认后由三人合并回 `docs/` 并补进 `openapi.yaml`。

---

## 1. 认证方式

| 项 | 取值 | 说明 |
| --- | --- | --- |
| 传输 | `Authorization: Bearer <token>` | 只用于 `/api/auth/me`、`/api/auth/logout`、`/api/me/**` |
| 令牌形态 | 43 字符 Base64URL 不透明串 | 客户端**不得解析**其内容 |
| 有效期 | 30 天 | 过期返回 `401 UNAUTHORIZED` |
| 服务端存储 | 只存 `SHA-256(token)` | 泄库也无法直接冒用 |
| 多设备 | 每次登录新建会话 | 一端登录/退出**不影响**其他设备（C1、C9） |
| 口令 | BCrypt（强度 10） | 服务端只存摘要；登录失败统一 `INVALID_CREDENTIALS`，不区分"用户不存在"与"密码错" |

> 未采用 JWT：C9 要求"退出一端不影响另一端"、README 要求"管理多设备会话"，
> DB 会话最直接；JWT 想撤销还得再建黑名单。

---

## 2. 接口清单

| # | 方法与路径 | 鉴权 | 说明 |
| --- | --- | --- | --- |
| 1 | `POST /api/auth/register` | 无 | 注册并**直接返回会话**（免二次登录），201 |
| 2 | `POST /api/auth/login` | 无 | 新建一个会话，旧会话保留 |
| 3 | `GET /api/auth/me` | Bearer | 当前用户 |
| 4 | `POST /api/auth/logout` | Bearer | 只结束当前设备的会话，204 |
| 5 | `GET /api/me/collections?page=&page_size=` | Bearer | 我的收藏（含作品摘要），按 `updated_at` 倒序 |
| 6 | `POST /api/me/collections/{work_id}` | Bearer | **加入收藏**（幂等），body 可带 `status` |
| 7 | `PATCH /api/me/collections/{work_id}` | Bearer | **只改状态**，收藏不存在时 409 `COLLECTION_REQUIRED` |
| 8 | `DELETE /api/me/collections/{work_id}` | Bearer | 取消收藏，204；重复调用不报错 |

### 2.1 注册 / 登录

```json
// POST /api/auth/register
{ "username": "alice", "password": "pw-12345678", "device_label": "phone" }

// 200/201 响应
{
  "token": "9Zk3...43字符...",
  "expires_at": "2026-11-19T09:00:00Z",
  "user": { "user_id": "U-9k2m0p7qz58f3a1", "username": "alice", "created_at": "2026-10-20T09:00:00Z" }
}
```

- `username`：3–32 字符，不能含空白；**大小写不敏感**（`Alice` 与 `alice` 是同一账号）
- `password`：8–72 字符
- `device_label`：可选，≤64 字符，仅用于展示与排查

### 2.2 收藏

```json
// POST /api/me/collections/W-3ar44z6wsbq0nyg
{ "status": "want" }

// 200 响应
{
  "work_id": "W-3ar44z6wsbq0nyg",
  "work_type": "anime",
  "title": "街角魔族 2丁目",
  "cover_url": "http://192.168.1.5:8080/api/covers/W-3ar44z6wsbq0nyg",
  "tags": ["日常", "搞笑"],
  "main_rating": { "value": 7.8, "scale": "0-10", "source": "otaku_site" },
  "status": "want",
  "updated_at": "2026-10-20T09:00:00Z"
}
```

- `status` 取值 `want` / `watching` / `watched`，可为 `null`（收藏但不设状态）
- 列表项复用接口③的作品摘要形态（**不含 `summary`**），客户端可共用同一套卡片
- 未收藏的作品不会出现在列表里；`work_id` 不存在时 `POST` 返回 404 `WORK_NOT_FOUND`

---

## 3. 状态语义（这是 Flutter 最需要对齐的部分）

| 场景 | 客户端动作 | 服务端行为 |
| --- | --- | --- |
| 收藏并设状态 | `POST` + `{"status":"want"}` | 不存在则插入；已存在且状态不同则更新 |
| 只改状态 | `PATCH` + `{"status":"watched"}` | 收藏不存在 → **409 `COLLECTION_REQUIRED`**，不自动重建 |
| 取消收藏 | `DELETE` | 删行，状态一并消失（C4）；重复调用 204 |
| 重试同一个写请求 | 原样重发 | 幂等：状态相同则不产生变化、`updated_at` 不动 |
| 两端同时改 | 各自提交目标状态 | **服务端最后成功提交生效**；不使用设备本地时间 |

**关键约束**：写接口只接受"目标状态"，不提供 `toggle`。
"切换状态"请求在网络重试时会反向操作，契约里已明确禁止（`project-plan-v2.md` §5.2）。

---

## 4. 错误码（相对阶段 1 新增）

| code | HTTP | 场景 | 客户端该怎么做 |
| --- | --- | --- | --- |
| `UNAUTHORIZED` | 401 | 未带令牌 / 令牌无效 / 已退出 / 已过期 | 清本地凭据，回到登录页 |
| `INVALID_CREDENTIALS` | 401 | 登录时用户名或密码错 | 提示"用户名或密码错误"，不重试 |
| `USERNAME_TAKEN` | 409 | 注册时用户名已存在 | 提示换一个 |
| `COLLECTION_REQUIRED` | 409 | 改状态时收藏已被（另一端）取消 | **提示刷新**，不得自动重新收藏（C11） |
| `WORK_NOT_FOUND` | 404 | 收藏一个不存在的 `work_id` | 提示并返回列表 |
| `BAD_REQUEST` | 400 | 参数非法（用户名长度、status 取值等） | 修正后重发 |

信封与阶段 1 完全一致：`{"error":{"code":"...","message":"..."}}`。

---

## 5. 验收对照（已实测）

| 项 | 结果 |
| --- | --- |
| C1 两端同时登录 | ✅ 两次登录得到不同 token，两个都可用，互不踢下线 |
| C2 手机收藏并设「想看」→ 桌面可见 | ✅ 桌面 `GET` 到同一条，`status=want` |
| C3 桌面改「看过」→ 手机可见 | ✅ 手机刷新后 `status=watched` |
| C4 一端取消 → 另一端该条与状态同时消失 | ✅ `DELETE` 后另一端 `total=0` |
| C5 B 看不到 A 的收藏 | ✅ B 的 `total=0`；同一作品两人各自一条，互不可见 |
| C6 退出 A 切 B 不残留 | ✅ 退出后旧 token 立即 401 |
| C9 手机退出后桌面仍可用 | ✅ 桌面 token 不受影响 |
| C10 重新登录后收藏仍在 | ✅ 收藏与状态完整保留 |
| C11 过期界面改状态 | ✅ 409 `COLLECTION_REQUIRED` |
| E7 越权读写 | ✅ 所有查询强制 `user_id = 当前会话`，接口不接受客户端传 `user_id` |
| 存储安全 | ✅ 库内口令为 `$2a$10$...`（60 字符 BCrypt），令牌仅存 64 位 SHA-256 |

---

## 6. 待 Flutter 确认

1. **令牌保存方式**：建议 `flutter_secure_storage`；退出登录/切账号时清理（C6）。
2. **`device_label`**：建议传 `android` / `windows` 之类，便于将来做"设备管理"。
3. **登录态失效处理**：收到 `401` 时清凭据并跳登录页，不要无提示重试。
4. **`PATCH` 而非 `PUT`**：只改状态用 `PATCH` 语义更准；若客户端 HTTP 栈不便发 `PATCH`，可改为 `PUT /status` 子路径，但需要先改这一份。
5. **列表分页**：`page_size` 默认 20、上限 50，与作品列表一致。

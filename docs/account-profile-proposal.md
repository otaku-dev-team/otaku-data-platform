# 账户信息页方案 · 已拍板（2026-11-05 修订）

> 状态：**#378 已由 zm 于 01:16 / 01:19 拍板，本文按拍板结论重写**。
> 归属：客户端 @riceyu02、后端 @pyxz0、存储与运维 @zhengmin486。
>
> ⚠️ **本文初版（#433）的 B / C「做不了」结论已作废**。作废原因见 §2；
> 修订依据：#378 的 01:16「三条约束逐条核对」与 01:19「otaku 自运营的约束让步口径」（#435）。
> 初版把「平台不代理来源站接口」「契约 §7 不回写」「交付形态不加文件存储」这三条
> 为多站交付设的限制，误当成了产品铁律——对自家站并不成立。

## 1. 三件事拆开看（现状）

| 子项 | 初版判断 | 现在 |
|---|---|---|
| A 账号菜单丰富化 | 能，纯客户端 | **已完成**：登录设备页 + 账号注销（#434，已合） |
| B 资料展示 / 编辑（昵称 + 简介） | 「契约禁止回写」→ 做不了 | **第一层客户端已提 PR #440**（编辑表单 + 首字色块兜底，mock 壳） |
| C 头像上传 | 「平台无文件存储」→ 不能做 | **第二层已拍板做**：本地目录 + Nginx 直出，后端 pyxz0 / 运维 zm |
| D 邮箱 / 手机绑定 | 没能力 | **唯一真外部依赖**（SMTP / 短信网关要采购与合规），明确押后 |

## 2. 旧约束为什么站不住

| 初版的理由 | 逐条核对后的结论 |
|---|---|
| `identity-linkup-contract.md` §7「`nickname` / `avatar_url` 仅展示，不回写、不再分发」 | §7 的上下文是**站点返回的身份信息**（别拷进我们库、别反复向站点拉），不禁止平台账号拥有自己的昵称和头像。两件事被合并成了一条禁令 |
| `User.display_name` 契约写「平台账号恒为 null」 | 字段一直在 `UserDto` 里，只是固定返回 null。三级漂移：契约「首期可不做」→ 实现固定 null → 描述写成「恒为 null」→ 被读成「不许做」。**资料编辑不需要新契约字段**，只要加列 + 一个 PUT |
| 后端没有 `MultipartFile`，做头像等于从零加存储 | 单站私有化部署，头像就是**本地目录 + Nginx 一行 `location`**，不需要对象存储 / CDN。真实成本是运维三件事：备份带上、注销删文件、磁盘监控 |
| 平台不代理 / 不改来源站接口 | #435（otaku 自运营）：自家站的接口可以要、可以加白名单、可以改。**仅「客户端不直连来源站」仍不让步** |

**仍然不让步的四条**（与是不是自己的站无关）：客户端不直连来源站、注销即清个人数据（#423）、
`site_key` 不写死、成人内容可见性与合规口径。跨模块契约仍走三人知悉——那是协作纪律，不是产品限制。

## 3. 拍板结论（#378，01:16）

| 层 | 内容 | 归属 | 状态 |
|---|---|---|---|
| 零 | 菜单丰富化（登录设备 / 注销） | 客户端 | **已合**（#434） |
| 一 | `PUT /api/me/profile`（昵称 / 简介）+ 客户端首字色块头像兜底 | 后端 pyxz0 / 客户端 riceyu02 | 客户端壳 **PR #440**；后端待确认 |
| 二 | `POST` / `DELETE /api/me/avatar` + 本地存储 + Nginx 直出 | 后端 pyxz0 / 运维 zm | 待开工 |
| 三 | 邮箱 / 手机绑定 | — | **押后，单独立项** |

**不做性别 / 生日 / 所在地**：敏感个人信息，做进来要额外告知与授权，收益只是「和网站一样」。
昵称 + 简介 + 头像已经解决「我在 app 里没有身份」这件事。

## 4. 数据层与契约（zm 给的形状，待 pyxz0 确认）

```sql
ALTER TABLE app_user
  ADD COLUMN display_name VARCHAR(32) NULL COMMENT '平台自设昵称；NULL=回落 username',
  ADD COLUMN bio          VARCHAR(200) NULL COMMENT '个人简介',
  ADD COLUMN avatar_key   VARCHAR(64) NULL COMMENT '头像文件名（不含路径）；NULL=首字色块';
```

`avatar_key` 存**文件名不存 URL**：换域名或换存储时不用回填。

契约（属跨模块，需三人知悉）：

- `User` 加 `avatar_url`（nullable，`null` = 用首字色块）；`display_name` 描述从「恒为 null」
  改为「可空；平台可自行设置，未设置回落 `username`」；
- `PUT /api/me/profile`：`{display_name, bio}` → `User`；长度与字符集校验，**空串归一为 null**；
- `POST /api/me/avatar`：multipart `file`，≤ 2MB，jpeg / png / webp，服务端重编码为 webp
  512×512（防伪装文件、去 EXIF 定位），返回 `{avatar_url}`；
- `DELETE /api/me/avatar`：204，删文件并置 null；每用户 1 分钟 1 次。

存储与运维：`${OTAKU_DATA_DIR}/avatars/{user_id}.webp`，Nginx `location /avatars/` 直出
`expires 7d`，备份纳入 avatars 目录。**注销时删文件**要新增
`AccountDeletionProfileListener`（照 #423 的 `AccountDeletionViewListener` 写）——
不加就是又一次「注销后个人数据还在」。

## 5. 客户端第一层（PR #440）

与 #427 画像壳同一套做法：**先把页面、校验、空值回落、四态写完，接口定稿后只改数据源**。

- 独立 `UserProfile` model + `ProfileDataSource`（当前只有 mock），**不动 `AccountUser`**；
- `ProfileEditPage`（`/me/edit`）：昵称 ≤32、简介 ≤200，空串归一 `null`；
- `UserAvatar` 抽成公开组件：有 `avatar_url` 显示图片，没有就首字色块（用 `characters` 取首字，
  避免 emoji 被切半个代理对）；第二层落地时只把 URL 传进来，组件不用改；
- 未登录给引导、加载中转圈、读取失败给重试、保存失败不假装成功（表单与输入保留）。

`flutter analyze` 无问题，相关 11 项测试通过。

## 6. 接下来（按顺序）

1. pyxz0 确认 §4 的端点与 `User.avatar_url`，以及「头像走本地目录 + Nginx」；
2. 后端落第一层（加列 + `PUT /api/me/profile`）→ 客户端把 `ProfileRemoteDataSource` 接上，删 mock；
3. 第二层头像上传 + 注销删文件；
4. 第三层邮箱 / 手机绑定单独立项。

## 7. 迁移号

**不要写死**。截至 2026-11-05：V32 已上线（#421 浏览表）、V31 永久跳过、V33 排给 #362；
#408 的映射表方案撤销后 **V34 已空出**（#436），#377 / #378 顺位使用。
合入时以 `ls backend-java/src/main/resources/db/migration/ | sort -V` 的实际最大号为准。

# 账户信息页方案 · 后端已实现（2026-11-07）

> 状态：**后端第一层 + 第二层已上线**（`V35__account_profile.sql` + `/api/me/account`，2026-11-07 b34），
> 客户端把 `ProfileRemoteDataSource` 接上即可。
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
| 一 | 资料读写（昵称 / 简介）+ 客户端首字色块头像兜底 | 后端 pyxz0 / 客户端 riceyu02 | **后端已实现**：`GET/PUT /api/me/account`；客户端壳 **PR #440**，待接 remote |
| 二 | 头像上传 / 删除 + 本地存储 + 直出 | 后端 pyxz0 / 运维 zm | **后端已实现**：`POST/DELETE /api/me/account/avatar`、`/avatars/{file}`、注销删文件、备份纳入 |
| 三 | 邮箱 / 手机绑定 | — | **押后，单独立项** |

**不做性别 / 生日 / 所在地**：敏感个人信息，做进来要额外告知与授权，收益只是「和网站一样」。
昵称 + 简介 + 头像已经解决「我在 app 里没有身份」这件事。

## 4. 数据层与契约（已按实现回填）

```sql
-- V35__account_profile.sql
ALTER TABLE app_user
  ADD COLUMN display_name VARCHAR(32) NULL COMMENT '平台自设昵称；NULL=回落 username',
  ADD COLUMN bio          VARCHAR(200) NULL COMMENT '个人简介',
  ADD COLUMN avatar_key   VARCHAR(64) NULL COMMENT '头像文件名（不含路径）；NULL=首字色块';
```

`avatar_key` 存**文件名不存 URL**：换域名或换存储时不用回填。

### 4.1 两个对方案的修正

1. **资料是独立资源 `AccountProfile`，没有往 `User` 里塞字段。**
   `User` 是登录身份（`/api/auth/me`、`/api/auth/site-login` 都返回），`display_name`
   在那里是**站点昵称、仅当次展示**；平台自设昵称是另一套语义、要落库。
   混在一个字段里，客户端无法区分「这是站点给我的」还是「我自己设的」。
   独立资源还避免每次登录响应多背 `bio` / `avatar_url`。
2. **路径用 `/api/me/account`，不是 `/api/me/profile`。**
   `GET /api/me/profile` 已被阿宅画像（#471）占用；同路径 GET 画像、PUT 资料
   会让「profile 到底是什么」不可解释。画像保持原路径不动（客户端 #375 还没接），
   资料用 account——它本来就是账号资源。

### 4.2 端点

| 方法 / 路径 | 语义 |
|---|---|
| `GET /api/me/account` | 资料：`user_id` / `username` / `display_name` / `bio` / `avatar_url` / `created_at` |
| `PUT /api/me/account` | `{display_name, bio}`，空串归一 `null`；昵称 ≤32、简介 ≤200，超限 400 |
| `POST /api/me/account/avatar` | multipart `file`，≤2MB，jpg/png/webp；重编码 512×512 后落盘，返回 `{avatar_url}` |
| `DELETE /api/me/account/avatar` | 204，删文件并置 null；幂等 |

### 4.3 头像处理与存储

- **只认魔数**（JPEG `FF D8 FF` / PNG 8 字节 / WebP `RIFF…WEBP`），不信任扩展名与 Content-Type；
- 解码前先看尺寸（单边 ≤10000、总像素 ≤4000 万），挡解压炸弹；
- 居中裁方 + 双三次缩放到 512×512，**重编码**（去 EXIF / 防伪装 / 控体积）；
  优先 WebP（`webp-imageio` 原生库），不可用时退回 JPEG（白底）；
- 文件名为 `{public_user_id}-{内容指纹8位}.{webp|jpg}`：URL 随内容变化，
  才敢用 `Cache-Control: public, max-age=604800, immutable`；换头像时旧文件删掉；
- 存储目录 `app.profile.avatar-dir`（默认 `./data/avatars`，生产 `/app/data/avatars`）；
- **直出由 Spring 负责**（`GET /avatars/{filename}`），不依赖 Nginx——P2 的 Nginx 配置
  已合并但域名未定、未启用。将来启用 Nginx 时换成 `location /avatars/ { alias ... }`
  即可，URL 不变；
- 同一用户 **1 分钟 1 次**上传，超限 429 + `Retry-After`；
- 注销时 `AccountDeletionProfileListener` 清 key + 删文件（先清 key 再删文件，
  文件删失败最多留孤儿，不会出现「库里有 key、URL 404」）；
- 生产 compose 增加 `avatar-data:/app/data/avatars` 持久卷；`deploy/backup.sh`
  每日把 avatars 目录打成 `${SITE_KEY}-${STAMP}-avatars.tar.gz`（失败只告警，不阻断库备份）。

### 4.4 验证

- 后端全量 **509 通过 / 0 skipped**（新增 3 条图片处理单测 + 6 条真库 IT：
  401 / 默认空资料 / 保存与校验 / 上传与公开读 / 非图片 400 与删除幂等 / 注销删头像）；
- `check-contract.py`：**77 path / 135 $ref / 115 schema**。

## 5. 客户端第一层（PR #440）

与 #427 画像壳同一套做法：**先把页面、校验、空值回落、四态写完，接口定稿后只改数据源**。

- 独立 `UserProfile` model + `ProfileDataSource`（当前只有 mock），**不动 `AccountUser`**；
- `ProfileEditPage`（`/me/edit`）：昵称 ≤32、简介 ≤200，空串归一 `null`；
- `UserAvatar` 抽成公开组件：有 `avatar_url` 显示图片，没有就首字色块（用 `characters` 取首字，
  避免 emoji 被切半个代理对）；第二层落地时只把 URL 传进来，组件不用改；
- 未登录给引导、加载中转圈、读取失败给重试、保存失败不假装成功（表单与输入保留）。

`flutter analyze` 无问题，相关 11 项测试通过。

## 6. 接下来（按顺序）

1. ~~pyxz0 确认端点与存储形态~~ **已确认并落地**（见 §4）；
2. 客户端把 `ProfileRemoteDataSource` 接上：`GET/PUT /api/me/account`，删 mock；
   身份卡与桌面菜单已有 `profileDisplayNameProvider`，换成 remote 后自动生效；
3. 头像：`_saveAvatar` 改成 `POST /api/me/account/avatar` → `update(avatarUrl: ...)` →
   `invalidate(profileProvider)`；选图 / 预览 / `UserAvatar.previewImage` 不用改；
4. 第三层邮箱 / 手机绑定单独立项。

## 7. 迁移号

**不要写死**。实际落地（2026-11-07）：
`V33` = #362（人物键前缀 + 列宽）、`V34` = #377（资讯收藏）、**`V35` = 本文（账号资料）**。
合入时以 `ls backend-java/src/main/resources/db/migration/ | sort -V` 的实际最大号为准。

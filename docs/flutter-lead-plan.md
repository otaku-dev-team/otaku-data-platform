# Flutter 负责人执行方案

> 依据 `otaku-project-plan-v2.md`（v0.3）编写，范围限定在 §4.1、§8、§9 中属于客户端的部分。
> 2026-10-20

## 0. 你的边界（一句话）

交付 `app-client/`：Android + Windows 两端可运行的 Flutter 客户端，包含浏览、搜索、详情、登录、收藏与观看状态，以及两端打包与联调说明。
**不负责**：网站接口实现（Java）、数据清洗（Python）、网页改造。

## 1. 核心判断：先契约，再 Mock，后联调

计划里最容易被做错的一件事，是"等 Java 把接口补好再开始写客户端"。三个人协作、Java 还要先摸清网站源码，这个等待期可能两到三周，会把你前期的时间全耗掉，等接口来了又要按实际返回结构返工。

正确顺序：

1. **你起草契约**（客户端视角的接口需求），Java 只需要在上面确认或反驳。
2. **你按契约写 Mock 实现**，UI 与业务逻辑全速推进，不阻塞。
3. 真接口到位后**只替换仓储层的实现**，页面代码零改动。

这要求你从第一天起就把 `data` 层做成"接口 + 两个实现（Remote / Mock）"，用 `--dart-define=USE_MOCK=true` 切换。这一条决定你六周里有多少时间在空转。

## 2. 技术选型（定下来就别再讨论）

| 关注点 | 选择 | 理由 |
| --- | --- | --- |
| 状态管理 | `flutter_riverpod` | 编译期安全、易测试，`ref.invalidate` 天然适合切换账号时清个人缓存 |
| 网络 | `dio` + 自定义 `Interceptor` | 需要统一处理 baseUrl、鉴权头、错误映射、日志，`http` 包得自己手写 |
| 路由 | `go_router` | 支持 `/contents/:id` 深链，桌面端可做双栏嵌套路由 |
| 模型 | `freezed` + `json_serializable` | 未知字段容错、可空字段、`copyWith` |
| 凭据存储 | `flutter_secure_storage` | Android Keystore / Windows wincred |
| 轻量缓存 | `shared_preferences` | 只存非敏感项（上次账号、列表快照） |
| 图片 | `cached_network_image` | 断网与滚动性能 |
| 窗口 | `window_manager`（仅桌面） | 最小尺寸、初始尺寸、标题 |

**不做**：Flutter Web（会带来 CORS 与另一套适配）、实时推送、离线编辑合并 —— 计划 §3.2 已明确首期不需要。

## 3. 目录结构

Feature-first，每个 feature 内部三层，data 层必须可替换：

```text
app-client/
  lib/
    main.dart
    app.dart
    core/
      config/env.dart              # --dart-define 读取 baseUrl / USE_MOCK
      network/dio_client.dart      # 拦截器
      network/api_exception.dart   # 统一错误类型
      storage/secure_store.dart
      router/app_router.dart
      theme/
    features/
      contents/
        data/  content_repository.dart（抽象）+ content_repository_remote.dart + content_repository_mock.dart
        domain/content.dart, paged_result.dart
        presentation/list/, detail/, search/
      auth/
        data/  auth_repository.dart + _remote/_mock
        presentation/login/
      collection/
        data/  collection_repository.dart + _remote/_mock
        presentation/
    shared/widgets/                # AsyncValueView / EmptyView / ErrorRetryView / AdaptiveScaffold
  test/
```

`shared/widgets` 里的三个状态组件请第一天就做掉，后面每个页面都要用，能省下大量重复代码。

## 4. 六周节奏

### 阶段 0（第 1 周）：契约 + 骨架

- 环境：Flutter stable、Android SDK 与模拟器、**Visual Studio 2022 + "使用 C++ 的桌面开发"工作负载**（缺这个 Windows 端根本 build 不了，先 `flutter doctor -v` 确认）。
- 建仓：`flutter create --platforms=android,windows --org com.otaku app_client`，落到 `app-client/`。
- 产出 `docs/openapi.yaml` 中属于客户端的那部分（可以先只写 3 个接口：列表、详情、登录）。
- 产出 `docs/api-client-needs.md`（见 §5），**这份东西交出去的时间决定你后面的时间**。
- 产出：两端都能跑起来，切 `USE_MOCK=true` 能看到假数据列表与详情。

### 阶段 1（第 2–3 周）：双端浏览

- 列表分页（滚动加载 + 下拉刷新）、搜索（输入防抖 300ms）、详情。
- 四态齐全：loading / empty / error+retry / data。缺图用占位、无简介显示占位文案，**不允许空白或报错页**。
- 抽 50–100 条样本，与网页逐字段核对至少 5 部作品（计划 §9 阶段 1）。
- 真接口联调：真机 + Windows 直连 `http://154.8.194.198:8000`。

### 阶段 2（第 4–5 周）：账号与个人数据

- 登录 / 当前用户 / 退出，token 存 secure storage，401 统一拦截 → 清会话 → 回登录页。
- 收藏与观看状态：**以服务端返回值为准**，不做本地乐观更新（或只做短暂乐观 + 失败回滚，且失败时绝不显示"已同步"）。
- 写请求**不自动重试**，或重试必须确保幂等（见 §5 第 4 条）。
- 切换账号必须 `ref.invalidate` 掉个人相关 provider，不能残留上个账号的界面。
- 按 §6 的 7 条用例逐条自测，录屏存档。

### 阶段 3（第 6 周）：打包交付

- Android：release APK，签名配置走 `key.properties`（不入库），确认 `applicationId` 与版本号。
- Windows：`flutter build windows --release`，注意目标机缺 VC++ 运行库的情况，在说明里写清。
- `docs/development.md`：两端怎么起、怎么切环境、怎么回退到上一版本。

## 5. 交给 Java 的接口需求单（可直接开 Issue）

> 这一段是本节最有价值的产出，建议直接复制成 Issue，标题 `[contract] 客户端首期接口需求`。

作为 Flutter 侧，我需要下面这些明确下来的东西，否则我只能一直用假数据：

1. **认证**：客户端登录用什么？如果是浏览器 Cookie 会话，请提供一个返回 **Bearer token** 的登录接口；需要写明有效期、是否需要 refresh、以及 401 的响应体长什么样。
2. **列表分页**：`GET /api/contents` 现在文档里没有分页参数。需要 `page` / `page_size`，响应请统一包成 `{items, total, page, page_size, has_next}`，不要裸数组（裸数组后续加字段会破坏兼容）。
3. **详情字段**：当前只返回 `id, title, type, summary, rating`。客户端需要 `cover_url, genres, year`（对应网页上已展示的信息）。字段没有就返回 `null`，不要省略 key。
4. **收藏与状态**：请给我**幂等**的写接口，例如 `PUT /api/me/collections/{content_id}`，body 明确目标状态 `{"status": "watching"}`。**不要给 toggle 接口**——网络重试会把用户的操作反转。同时请明确：status 枚举全部取值、是否允许 null、取消收藏与清除状态是什么关系。
5. **错误格式**：统一 `{"code": "...", "message": "...", "trace_id": "..."}`，并约定 400/401/403/404/409 的语义。客户端要给用户可读的提示，靠猜 HTTP 状态码不够。
6. **版本兼容**：客户端会忽略未知字段，但请**不要删除或改名字段**；确需变更时提前在 `openapi.yaml` 的 PR 里体现。
7. **联调条件**：测试环境地址 + 测试账号 A / B（对应 §9 阶段 2 的双账号隔离验收）。
8. **并发**：同一条记录两端同时改时采用什么策略？服务端最后写入生效（LWW）还是带版本号返回 409？客户端要按结论实现，不能各端自己选。

## 6. 两端差异清单（漏一条就是验收不通过）

| 项 | Android / 手机 | Windows / 桌面 |
| --- | --- | --- |
| 主导航 | `NavigationBar`（底部） | `NavigationRail`（≥600px 宽） |
| 列表布局 | 单列无限滚动 | 自适应网格 2–4 列 |
| 详情 | 整页 push | ≥900px 时左右双栏（列表 + 详情） |
| 刷新 | 下拉刷新 | 刷新按钮 + `Ctrl+R` |
| 返回 | 系统返回手势 | `Esc` / 面包屑 |
| 搜索 | 软键盘、点空白收键盘 | 物理键盘 `Tab` 顺序 + `Enter` 提交 |
| 悬停 | 无 | 列表项 hover 高亮、可点击指针 |
| 窗口 | 全屏 | 最小 900×600，尺寸可记忆 |
| 明文 HTTP | **必须配 `network_security_config`**（Android 9+ 默认禁 cleartext） | 无需配置，但注意防火墙 |
| 凭据 | Keystore | wincred（单条有长度上限，token 别塞太长） |

## 7. 会踩的坑（先记住，能省两天）

1. **Android 模拟器访问 `localhost` 无效**，要用 `10.0.2.2`。但本项目后端是真实 IP，直接连 IP 就行——计划 §9 阶段 1 特意点了这条，说明容易被忽略。真机测试才是有效验证。
2. **Windows 端 build 失败**九成是缺 VS 的 C++ 工作负载，`flutter doctor -v` 里那一行必须是绿色。
3. **`flutter_secure_storage` 在 Windows 上**依赖 VC++ 运行库，且写入内容过长会失败——只存 token，别存整个用户对象。
4. **toggle 收藏 + 网络重试 = 数据被反转**，这是设备间不一致最常见的来源。见 §5 第 4 条。
5. **深色/浅色与 DPI**：Windows 高 DPI 下按 `devicePixelRatio` 取图，否则封面糊。
6. **release 包里不要依赖 assert 或调试日志**做逻辑判断。

## 8. 验收 checklist（对应计划 §9 阶段 2）

| # | 用例 | 判定 | 存档 |
| --- | --- | --- | --- |
| 1 | A 的**平台账号**可登录手机与桌面，平台内新增的收藏两端可见 | 两端条数与内容一致（不与来源站比对，见下方注） | 截图 ×2 |
| 2 | 手机收藏 → 桌面端刷新可见 | 桌面端出现该条 | 录屏 |
| 3 | 桌面端改观看状态 → 手机端刷新可见 | 状态文案一致 | 录屏 |
| 4 | 桌面取消收藏 / 清除状态 → 手机端按规则显示 | 与 Java 确认的规则一致 | 录屏 |
| 5 | B 无法读写 A 的数据；切账号不残留 A 的界面 | 切账号后列表与收藏清空 | 截图 |
| 6 | 退出再登录数据保留，多设备会话符合约定 | 仅结束当前会话 | 录屏 |
| 7 | 并发修改 / 重复请求 / 超时后结果符合契约，失败不误报成功 | 无"已同步"假象 | 录屏 |

> **注（2026-10-21 按 Issue #32 评审结论修订）**：账号改为**平台自建**（来源站只有作品接口，没有任何认证能力），
> 所以第 1 条不再是"网站账号"，判定也不与网页收藏数比对。
> 第 2–4 条同步把"网页"改为"另一端客户端"：账号自建后网站没有平台账号体系，跨端一致性**只能在平台的两个客户端
> （Windows 桌面 + Android）之间验证**，写"网页"会得到一条无法执行的验收项。
> 第 3 条原写"网页改观看状态"，现在由桌面端承担发起方，保持与第 2 条一正一反的对称。

> **验收记录**：2026-10-21 已在 Windows 桌面 + Android 模拟器（Pixel 5 / API 35）上逐条实跑，
> 7 条全部通过，过程与发现的问题见 [`stage2-acceptance.md`](stage2-acceptance.md)。
> 真机、弱网恢复、桌面键盘操作仍未覆盖，见该文档末节。

## 9. 协作纪律

- 分支：`feat/contents-list`、`feat/auth` 一类，一功能一 PR；模块内部实现自主决定，接口契约改动必须先在群里说。
- Issue 标签：`flutter`、`contract`；被后端阻塞的加 `blocked-by: java`。
- `docs/openapi.yaml` 是唯一契约来源，客户端不要对着网页 HTML 结构或文件名去猜接口。
- 联调只用测试账号，不要在现网数据上试写接口。

# app-client

Flutter 跨平台客户端。负责人：**Flutter 负责人**。

## 职责

- 作品浏览、搜索、详情展示，以及个人收藏与观看状态的管理界面。
- 调用 Java 后端提供的 API 获取与提交数据。
- 处理加载中、空结果、请求失败与字段缺失等界面状态。

## 目标平台

首期为**安卓手机 + Windows 桌面**双端，两端共用同一套服务与账号体系。
该组合由团队确认，其余平台作为后续扩展。

## 边界

- 只调用 Java 的业务接口，**不直接访问数据来源**，也不自行拼装作品数据。
- 不持有数据导入服务的密钥。
- 个人数据以服务端记录为准，客户端不做离线写入合并。
- `cover_url` 一律使用 Java 代理后的地址，**不拼来源站域名**。

## 状态

工程已初始化（Flutter 3.47 / Dart 3.13），第一阶段骨架完成：

- 分层结构：`core`（配置、网络、路由、主题）、`data`（模型、数据源、仓储）、`features`（列表、详情）、`shared`（公共组件）。
- 两条页面能力：作品列表（搜索 + 类型筛选 + 分页）与作品详情。
- 默认走 **Mock 数据源**，不依赖后端即可运行；真接口就绪后只替换 `data/datasources/`。
- **真接口已联调**（2026-10-21）：Windows 与 Android 双端跑通，数据为来源站真实记录
  （108 条，含 7225 字超长简介、三条同名「铁臂阿童木」、跨类型同名「航海王」、无封面记录），
  接口③④⑤ 按契约逐项核验通过，详见下方「切换真实接口」。
- **阶段 2 骨架已就位**（2026-10-21，见下方「阶段 2 骨架」）：登录页、我的收藏、令牌安全存储、
  401 拦截的落点。接口**仍是 Mock**，等阶段 2 契约定稿（Issue #32）后替换数据源。

## 环境要求

| 项 | 版本 / 位置 |
| --- | --- |
| Flutter | 3.47.7 stable（Dart 3.13.5） |
| Android SDK | platform 36、build-tools 36.0.0、NDK 28.2.13676358 |
| Windows 桌面 | Visual Studio 2022 Build Tools（含 C++ 桌面开发） |

> 阶段 2 引入 `flutter_secure_storage` 后，桌面端构建需要 **C++ ATL** 组件（`atlstr.h`）。
> 本机已用「从同名 MSVC 版本补齐 `atlmfc`」的方式解决，步骤与撤销方法见
> [`../docs/dev-setup.md`](../docs/dev-setup.md) 第 5.1 节。换机器优先用 VS 安装器勾选
> 「C++ ATL for latest v143 build tools」。

## 运行

```bash
cd app-client

flutter pub get

# Windows 桌面
flutter run -d windows

# Android（先启动模拟器或连上真机）
flutter run -d <device-id>
```

### 切换真实接口

默认 `USE_MOCK=true`，不依赖后端即可运行。跑真接口**必须先把 Java 后端起来**，
否则界面只会停在「网络好像不太行 / 请求超时」，这不是客户端的问题：

```bash
# 1. 准备库（MySQL 8，任意实例均可；表结构由 Flyway 自动建）
mysql -u root -p < ../backend-java/src/main/resources/db/manual/00-create-database.sql

# 2. 起后端（换掉 DB_PORT / DB_USER / DB_PASSWORD 以匹配你的实例）
cd ../backend-java
DB_HOST=127.0.0.1 DB_PORT=3306 DB_USER=root DB_PASSWORD=*** \
  OTAKU_INTERNAL_TOKEN=dev-token ./mvnw spring-boot:run
curl http://localhost:8080/actuator/health    # 期望 {"status":"UP"}

# 3. 灌数据（Java 自带样本，3 条；真数据可跑 sync-python）
curl -X POST http://localhost:8080/internal/import/batches \
  -H "Content-Type: application/json" -H "X-Internal-Token: dev-token" \
  -d @samples/import-batch-sample.json
```

然后客户端关掉 Mock：

```bash
# Windows 桌面（不传 API_BASE_URL 时默认就是 127.0.0.1:8080）
flutter run -d windows --dart-define=USE_MOCK=false

# Android 模拟器（默认 10.0.2.2:8080，不用传 API_BASE_URL）
flutter run -d emulator-5554 --dart-define=USE_MOCK=false
```

- 桌面端默认 `http://127.0.0.1:8080`，Android **模拟器**默认 `http://10.0.2.2:8080`
  （模拟器里的 `127.0.0.1` 指向模拟器自己）。
- **真机**不要用 `10.0.2.2`：要么传局域网 IP，要么做端口反向映射后仍是 `127.0.0.1`：

  ```bash
  adb reverse tcp:8080 tcp:8080
  flutter run -d <设备id> --dart-define=USE_MOCK=false \
    --dart-define=API_BASE_URL=http://127.0.0.1:8080
  ```

- `cover_url` 由后端按**当前请求的 host** 拼成自己的代理地址（`/api/covers/{work_id}`），
  所以桌面、模拟器、真机都不需要改后端配置，客户端原样消费即可，**不要自己拼来源站域名**。
- 明文 HTTP：`network_security_config.xml` 目前只对 `154.8.194.198` 放行，但客户端走的是
  dart:io 裸 socket，实测 `10.0.2.2` / `127.0.0.1` 的明文请求正常。这个行为不要当作契约依赖——
  换成 HTTPS 域名，或将来引入走系统网络栈的插件时，仍需把地址补进该配置。

### 检查与测试

```bash
flutter analyze
flutter test

# 构建产物（注意 build/ 已被 .gitignore 忽略，不要提交）
flutter build windows --release
flutter build apk --release
```

## 目录

```
lib/
├── main.dart                     入口，桌面端窗口初始化
├── app.dart                      MaterialApp + 主题 + 路由
├── core/
│   ├── config/app_config.dart    baseUrl / USE_MOCK / 分页上限
│   ├── network/                  dio 实例、错误拦截器、ApiException
│   ├── router/                   go_router 路由表与路径常量
│   ├── storage/token_store.dart  登录令牌（flutter_secure_storage）
│   └── theme/                    主题与布局尺寸
├── data/
│   ├── models/                   WorkSummary（6 字段）、Work（10 字段）、AccountUser、CollectionEntry
│   ├── datasources/              remote（真接口）与 mock；auth / collection 目前只有 mock
│   └── repositories/             唯一数据入口，异常收敛；AuthRepository 管令牌生命周期
├── features/
│   ├── auth/                     登录页与会话状态机
│   ├── collection/               我的收藏：状态筛选、改状态、取消收藏
│   ├── contents/                 列表：搜索、筛选、分页、空态、错误态
│   └── detail/                   详情：封面、元信息、简介折叠
└── shared/widgets/               封面、评分、标签、空态、错误态、骨架屏
```

## Mock 数据

`assets/mock/works_catalog.json` 与 `assets/mock/works_details.json` 由
[`../docs/samples/stage0-sample.json`](../docs/samples/stage0-sample.json) 转出，
保留了验收需要的边界用例：

| 用例 | 在哪条数据 |
| --- | --- |
| 7225 字超长简介 | `NHK15个动画短片` |
| 极短简介 `TV二期。` | `零度战姬Vibration` |
| 三条同名「铁臂阿童木」 | 列表第 1 页 |
| 跨类型同名「航海王」 | anime 与 comic 各一条 |
| 无封面 / 无评分 / 无标签 | 散布在列表中，用于验证占位与"不渲染" |

Mock 数据源在本地模拟了服务端的过滤、分页与 404 语义，所以从 Mock 切到真接口时，
页面行为不会突变。

## 封面占位

bangumi 档案没有封面字段，`cover_url` 全为 `null`（10,001 条），所以"没有封面"是常态
而不是异常。`shared/widgets/cover_image.dart` 把三种缺失状态分开画：

| 状态 | 表现 | 理由 |
| --- | --- | --- |
| `cover_url` 为 `null` / 空串 | 品牌色渐变 + 斜纹 + **标题首字**（列表/收藏卡片）；详情页没有传首字，退回图标 + 「暂无封面」 | 契约 6.3 要求占位，且要让用户看出是"本来没有"而不是加载失败 |
| 图片加载中 | 纯灰底骨架，不画图标也不画文字 | 与"没有封面"区分开，避免闪一下图标再变图片 |
| 图片加载失败 | 与"没有封面"同款 | 契约 6.3 不允许出现破图 |

渐变与斜纹取自来源站 `.work-cover`：大面积纯色块看着像加载失败，加一层 135° 斜纹和
首字，观感上是"这张卡有内容但没配图"。首字用 `characters` 取整字，emoji 不会被截半个。

## 视觉

桌面端**照来源站的样式体系做**，不是自己另起一套：色值直接取自站点
`static/style.css` 的设计变量，两个端之间切换不会有"换了个软件"的感觉。

| 项 | 取值 | 对应站点变量 |
| --- | --- | --- |
| 主色 | `#2A9AE0` | `--brand-600` |
| 描边 / hover | `#85CDFF` | `--brand-300` |
| 浅底 | `#F1F6FC` | `--surface` |
| 卡片 | `#FFFFFF` + `1px #DFE9F4` 描边 | `--card-bg` |
| 圆角 | 16 | `--radius-lg` |
| 强调青 | `#39C5BB` | `--accent-500` |

列表与收藏都是 **2:3 海报网格**：列数按可用宽度算（桌面最小 190、手机 150），
卡片高度写死 `mainAxisExtent`，长短标题不会让行高参差；hover 抬起 4px、描边变浅、
阴影加深，与站点 `.work-card:hover` 一致。

站点卡片里的**两行摘要**和**排名角标**这里没有：列表接口不返回 `summary`，也没有
`rank` 字段。要补只能逐条请求详情，代价大于收益。

## 阶段 2 骨架

> 契约见 [`../docs/stage2-account-collection-contract.md`](../docs/stage2-account-collection-contract.md)，
> **仍在评审（Issue #32）**。所以这一层目前只接 Mock，形状按草案写；
> 定稿后只替换 `data/datasources/` 里的实现，页面与控制器不动。

已就位：

| 能力 | 位置 | 说明 |
| --- | --- | --- |
| 登录页 | `features/auth/login_page.dart` | 账号密码 + 失败提示；不重复实现服务端的校验规则 |
| 会话状态机 | `features/auth/auth_controller.dart` | 三态 `checking / signedOut / signedIn`，冷启动不闪登录页 |
| 令牌存储 | `core/storage/token_store.dart` | `flutter_secure_storage`，**只存令牌**，不存用户对象 |
| 我的收藏 | `features/collection/collection_page.dart` | 状态筛选、改状态、取消收藏、登录引导、空/错/加载四态 |
| 401 统一失效 | `core/network/session_expiry.dart` + dio 拦截器 | 任一请求 401 `UNAUTHORIZED` → 清会话回登录页 |

几条硬规则在代码里的落点（改代码前先看这几处）：

- **不用 toggle**：收藏/取消收藏是「声明目标状态」的幂等写请求，不是翻转。
- **`PUT` 只 upsert、`PATCH` 只改不建**：`CollectionDataSource` 的注释写死了这条。
  改状态用 `PUT` 会把「已取消收藏的作品」静默重新收藏，验收项 C11 直接失败。
- **401 有两种 code**：`UNAUTHORIZED`（令牌失效，清会话）与 `INVALID_CREDENTIALS`
  （登录密码错，**不能**清已有会话）。只看 HTTP 状态码会把两者搞混。
- **不做乐观更新**：写请求成功后用服务端返回值更新界面；失败只提示，不把界面改成"好像成功了"。
- **切账号不残留**：`CollectionController` `watch` 当前 `user_id`，用户一变自动重查，
  不需要手动 `ref.invalidate` 一堆 provider。

尚未做（等契约定稿或排期）：详情页的收藏按钮、`RemoteAuthDataSource`/`RemoteCollectionDataSource`、
收藏列表分页（契约要求 `page_size` 上限 50，当前 Mock 一次取完）。

手工验证（无需后端）：

```bash
flutter run -d windows          # 默认 USE_MOCK=true
# 作品库右上角书签 → 我的收藏 → 去登录
# 任意非空账号密码可登录；密码填 wrong 可看失败提示
# 关掉再开，收藏页应仍是登录态（令牌已进 Windows 凭据管理器）
```

## 约定

- 两端共享作品模型、API 调用与登录逻辑，仅按屏幕尺寸与输入方式调整界面。
- 两端分别构建、运行和验收，不以一端运行成功推定另一端可用。
- 接口与字段以 [`../docs/stage1-minimal-contract.md`](../docs/stage1-minimal-contract.md) 为准（第一阶段）；更完整的范围、阶段划分与验收步骤见 [`../docs/otaku-project-plan-v2.md`](../docs/otaku-project-plan-v2.md) 与 [`../docs/acceptance.md`](../docs/acceptance.md)。
- `work_id` 是不透明字符串，不解析、不做数值比较；列表不返回 `summary`，需要简介请拉详情。

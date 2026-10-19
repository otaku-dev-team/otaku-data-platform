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

## 环境要求

| 项 | 版本 / 位置 |
| --- | --- |
| Flutter | 3.47.7 stable（Dart 3.13.5） |
| Android SDK | platform 36、build-tools 36.0.0、NDK 28.2.13676358 |
| Windows 桌面 | Visual Studio 2022 Build Tools（含 C++ 桌面开发） |

> 第二阶段引入 `flutter_secure_storage` 前，需要先在 VS 安装器里勾选
> 「C++ ATL for latest v143 build tools」。缺这个组件时桌面端构建会报
> `atlstr.h: No such file or directory`——第一阶段没有认证，所以该依赖暂未引入。

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

默认 `USE_MOCK=true`。后端就绪后：

```bash
flutter run -d windows \
  --dart-define=USE_MOCK=false \
  --dart-define=API_BASE_URL=http://127.0.0.1:8080
```

不传 `API_BASE_URL` 时，桌面端默认 `http://127.0.0.1:8080`，Android 模拟器默认
`http://10.0.2.2:8080`（模拟器里的 `127.0.0.1` 指向模拟器自己）。

> Android 只对 `154.8.194.198` 放行了明文 HTTP（见
> `android/app/src/main/res/xml/network_security_config.xml`）。
> 如果后端跑在其他 `http://` 地址上，需要把该地址加进去，或者直接上 HTTPS。

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
│   └── theme/                    主题与布局尺寸
├── data/
│   ├── models/                   WorkSummary（6 字段）、Work（10 字段）、分页容器
│   ├── datasources/              remote（真接口）与 mock（assets/mock）
│   └── repositories/             唯一数据入口，异常收敛
├── features/
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

## 约定

- 两端共享作品模型、API 调用与登录逻辑，仅按屏幕尺寸与输入方式调整界面。
- 两端分别构建、运行和验收，不以一端运行成功推定另一端可用。
- 接口与字段以 [`../docs/stage1-minimal-contract.md`](../docs/stage1-minimal-contract.md) 为准（第一阶段）；更完整的范围、阶段划分与验收步骤见 [`../docs/otaku-project-plan-v2.md`](../docs/otaku-project-plan-v2.md) 与 [`../docs/acceptance.md`](../docs/acceptance.md)。
- `work_id` 是不透明字符串，不解析、不做数值比较；列表不返回 `summary`，需要简介请拉详情。

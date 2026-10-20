# Flutter 端开工准备（依据 2026-10-20 ea4294f 的文档）

> 依据：`docs/stage1-minimal-contract.md`（草案）、`docs/openapi.yaml`（1.0.0-draft）、`docs/acceptance.md`、Issue #19。
> 范围：第一阶段，Android + Windows 双端。

---

## 0. 一句话结论

第一阶段客户端只有两个页面能力：**作品列表（含搜索）+ 作品详情**。账号、收藏是阶段 2，现在不做。

**脚手架现在就能 100% 做完，不用等 Java。** 卡点不在框架，在真实接口地址。

---

## 1. 任务边界（Issue #19）

| 交付 | 说明 |
| --- | --- |
| 可运行客户端 | 列表、详情、基础搜索 |
| 界面状态处理 | 空状态、加载中、错误、字段缺失 |
| 运行说明 | 写进 `app-client/README.md` |

不在范围内：登录、收藏、观看状态、离线缓存、多站点切换、Flutter Web。

---

## 2. 契约里对客户端的硬约束

这些不是建议，是违约就要返工的条款。写代码时逐条核对。

| # | 约束 | 出处 | 代码落点 |
| --- | --- | --- | --- |
| 1 | `work_id` 是**不透明字符串**，不得解析结构、不得数值比较 | 2.1 / 3.3 | 模型字段用 `String`，禁止 `int.parse` |
| 2 | 列表**只有 6 个字段**，没有 `summary` | 2.1 / 6 | `WorkSummary` 模型不带 summary |
| 3 | 可空字段一律 `null`，客户端**不得显示 `0`、`"无"` 之类伪值** | 2.3 | 空值判断在 UI 层统一做 |
| 4 | 不得用 `title` 判重（实测 anime 内重名 55 组） | 3.3 | 不做本地去重 |
| 5 | 列表里没出现的作品**不代表已删除** | 3.3 | 不做"缺失即删除"推断 |
| 6 | `cover_url` 为 `null` → 显示占位图，不得空白或报错图 | 6.3 | `CoverImage` 组件统一处理 |
| 7 | `main_rating` 为 `null` → **不显示评分区**，不得显示 `0.0` | 6.3 | 条件渲染整块 |
| 8 | `summary` 为 `null` → "暂无简介"；非 null 按 `\n` 分段 | 6.3 | 详情页解析换行 |
| 9 | `tags` 为 `null` 或 `[]` → 不渲染标签区 | 6.3 | 空集合直接 return |
| 10 | 详情 `404` → 提示并返回列表，**不自动重试** | 6.2 | 详情页错误分支 |
| 11 | 错误响应统一 `{"error":{"code","message"}}` | 7 | 全局异常模型 + 拦截器 |
| 12 | `page_size` 默认 20、**上限 50**，超了服务端截断不报错 | 6.1 | 常量 `kPageSize = 20` |
| 13 | `q` 只匹配标题子串、忽略大小写，**不支持别名与拼音** | 6.1 | 搜索框提示语别写"支持别名" |
| 14 | 运行期不切换站点，请求**不传站点参数** | 9 | 站点标识只放配置 |

错误码只有 6 个：`UNAUTHORIZED` `BAD_REQUEST` `WORK_NOT_FOUND` `BATCH_TOO_LARGE` `RATE_LIMITED` `INTERNAL`。客户端只会遇到前三个和 `INTERNAL`。

---

## 3. 现在就能做 vs 必须等 Java

| 事情 | 能否现在做 | 说明 |
| --- | --- | --- |
| lib 分层骨架 | ✅ | 纯结构 |
| 主题 / 路由 | ✅ | 已定 Riverpod + go_router |
| dio 封装 + 错误模型 | ✅ | 信封格式已定，照着写 |
| 数据模型 | ✅ | openapi 里 schema 完整 |
| Mock 数据源 + `USE_MOCK` 开关 | ✅ | 见下节注意 |
| 列表页 / 详情页 / 搜索 | ✅ | 用 Mock 先跑通 |
| 真实联调 | ❌ | 等 Java 给 base URL |
| Android 明文 HTTP 例外 | ⚠️ | 首期 Java 可能跑在 `http://`，配置保留 |

### Mock 数据不能直接用现成样本

`docs/samples/stage0-sample.json` 是**导入侧格式**（`cases[].records[].raw` + `source_record`），不是客户端的响应格式，**不能直接喂给 data 层**。

但它很有价值——10 个用例专门覆盖边界：7225 字超长简介、`"TV二期。"` 极短简介、三条重名「铁臂阿童木」、空标签、无评分、`\r\n` 换行。

**建议**：写个脚本把它转成两份符合接口形状的 JSON 放进 `assets/mock/`：
- `works_catalog.json` —— 列表全量（24 条，含 `{total, page, page_size, total_pages, items}` 外壳）
- `works_details.json` —— `work_id → 详情对象` 的映射（10 字段）

这样 Mock 的边界用例和验收清单 B6/B7/B9 天然对齐。

---

## 4. 脚手架文件清单

```
app-client/lib/
├── main.dart                         入口，桌面端窗口初始化
├── app.dart                          MaterialApp + theme + router 装配
├── core/
│   ├── config/app_config.dart        baseUrl / useMock / pageSize
│   ├── network/
│   │   ├── dio_client.dart           dio 实例、超时、日志拦截器
│   │   ├── api_exception.dart        统一异常（code + message + statusCode）
│   │   └── error_interceptor.dart    解析 {error:{...}} 信封
│   ├── router/
│   │   ├── app_router.dart           列表、详情两条路由
│   │   └── route_paths.dart          路径常量，跳转不写字面量
│   └── theme/
│       ├── app_theme.dart            主题（已有）
│       └── app_layout.dart           宽度断点与间距
├── data/
│   ├── models/
│   │   ├── work_type.dart            四值枚举 + unknown 兜底
│   │   ├── work_summary.dart         6 字段
│   │   ├── work.dart                 10 字段
│   │   ├── source_rating.dart        {value, scale, source}
│   │   └── paged_result.dart         泛型分页容器，跳过坏数据
│   ├── datasources/
│   │   ├── work_data_source.dart     抽象接口
│   │   ├── work_remote_datasource.dart
│   │   └── work_mock_datasource.dart  读 assets/mock
│   └── repositories/work_repository.dart
├── features/
│   ├── contents/                     列表 + 搜索 + 分页
│   └── detail/                       详情 + 简介折叠
└── shared/widgets/
    ├── cover_image.dart              null → 占位图
    ├── rating_badge.dart             null → 整块不渲染
    ├── tag_chips.dart                空集合 → 不渲染
    ├── work_type_tag.dart
    ├── empty_state.dart
    ├── error_state.dart              带重试按钮（404 时不给）
    └── skeleton_list.dart            列表与详情骨架屏
```

`features/` 下每条分支只填自己的目录，`core/`、`data/`、`shared/` 在脚手架阶段定死。

**模型不用 freezed / json_serializable。** 字段就 6 个和 10 个，手写 `fromJson`
省掉 build_runner 这一步，也避免生成的代码在评审时变成大片噪音。等模型数量上来再引入。

**两处实现上的坑（已踩过）**

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| Windows 构建报 `atlstr.h: No such file or directory` | `flutter_secure_storage` 的 Windows 插件依赖 ATL | 第一阶段不引入该依赖；第二阶段先在 VS 安装器勾选「C++ ATL for latest v143 build tools」 |
| 详情 404 一直停在骨架屏，看不到错误 | Riverpod 3 默认对失败的 provider **自动重试**（指数退避） | `retry: (count, error) => null` 关掉，契约 6.2 要求 404 不自动重试 |

---

## 5. 界面状态矩阵

照着这张表写，验收时一条条对。

| 情况 | 显示 | 验收项 |
| --- | --- | --- |
| 首屏加载 | 骨架屏（不是转圈遮罩） | — |
| 列表为空（无筛选） | 空状态文案 | B3 |
| 搜索无结果 | "没有匹配的作品" | B3 |
| 加载下一页失败 | 底部重试条，**不清空已有数据** | B10 |
| 断网 | 明确错误 + 重试按钮，不静默失败 | B10 |
| `cover_url` 为 null | 占位图 | B5 |
| `main_rating` 为 null | 不显示评分区 | B4 |
| `summary` 为 null | "暂无简介" | B4 |
| `summary` 7225 字 | 折叠，默认显示 4~6 行 | B6 |
| `summary` 极短 | 不撑出大块空白 | B7 |
| `summary` 含 `\n` | 按段落渲染 | B8 |
| 三条同名作品 | 三条独立记录，靠评分区分 | B9 |
| 详情 404 | 提示 + 返回列表 | — |

---

## 6. 文档里三处不一致，建议你提出来

| # | 问题 | 位置 |
| --- | --- | --- |
| 1 | 验收清单写"首期所有作品均**无封面**"，但契约 2.1 已定封面由 Java 代理+缓存，`cover_url` 会有值。B5 的前提过期了 | `acceptance.md` B5 vs 契约 2.1 |
| 2 | B9 要求重名作品"可通过**评分或简介**区分"，但列表不返回 `summary`，列表里只能靠评分 | `acceptance.md` B9 vs 契约 6.1 |
| 3 | Issue #3 第 7 项「列表不返回 `summary`」仍标着待 **Flutter** 确认 | 契约第 10 节 |

前两条建议直接改 `acceptance.md`（属于契约维护，走 `docs/*` 分支）；第三条在 Issue #3 回一句"接受"即可。

另外第 10 节里 #1、#3、#4 三项需要**三人**确认，目前也还挂着。

---

## 7. 建议的动作顺序

1. 在 Issue #3 回复第 7 项（一句话，解除 Java 的等待）
2. 脚手架：模型 + dio + 错误模型 + Mock 数据源
3. 列表页跑通 Mock（含分页、搜索、空态）
4. 详情页跑通 Mock（含超长简介折叠）
5. 双端各跑一遍，截图存档
6. 更新 `app-client/README.md` 的运行说明
7. 提交 PR，等 Java 接口就绪后只替换 `datasources/`

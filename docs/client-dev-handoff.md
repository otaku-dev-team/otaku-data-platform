# 客户端对接现状（全量数据导入期间）

给客户端开发的对接说明。**结论：浏览类功能现在就能开发联调，不需要等数据灌完**；
封面与登录/收藏两处尚不可用，按占位与 mock 处理。

本文所有结论均于 2026-10-27 23:50 对生产后端实测，不是设计稿推断。

## 1. 接入地址

```
Base URL: http://154.8.194.198:8080
```

- 明文 HTTP。`app-client/android/app/src/main/res/xml/network_security_config.xml`
  已对 `154.8.194.198` 显式放行 `cleartextTrafficPermitted`，release 包可直连，
  不需要等 HTTPS/域名（那一步留到上架前）。
- **这是开发环境，不是生产环境。** 它会持续被灌数据，不保证留存，勿做写操作、勿压测。

## 2. 接口能力实测

| 接口 | 状态 | 实测 |
| --- | --- | --- |
| `GET /api/works` 列表 | 可用 | 200，约 0.1s |
| `GET /api/works/{work_id}` 详情 | 可用 | 200，12 字段，简介/标签/年份齐全 |
| `GET /api/works/{work_id}/related` 同标签推荐 | 可用 | 200，约 0.19s |
| `GET /api/schedule` 新番档期 | 可用 | 200 |
| `GET /api/articles` 资讯 | 可用 | 200 |
| `GET /api/covers/{work_id}` 封面 | **基本 404** | 60 条抽样：2 条 200 / 58 条 404 |
| `POST /api/auth/site-login` 登录 | **不存在** | 404 |
| `/api/me`、`/api/collections` 收藏 | **不存在** | 404 |

登录与收藏属阶段 2 账号绑定，契约已合并、尚未实现。因此
「浏览 → 详情 → 收藏 → 追番」这条闭环暂时只能本地 mock，不能对着后端联调。

## 3. 参数速查

列表接口 `GET /api/works`：

| 参数 | 取值 | 说明 |
| --- | --- | --- |
| `q` | 关键词 | 标题搜索。**注意参数名是 `q`**，不是 `keyword` |
| `type` | `anime` / `comic` / `game` / `novel` | 作品类型 |
| `tag` | 标签名 | 按标签筛选 |
| `sort` | `id` / `rating` / `year` | 默认 `id` |
| `min_rating` | 数字 | 评分下限 |
| `page` | 从 **1** 开始 | 不是 0-based |
| `page_size` | 默认 20 | 上限见契约 |

响应为 `{page, page_size, total, total_pages, items}`。

**所有 JSON 字段统一 snake_case**（`work_id`、`cover_url`、`release_year`、`basis_tags`），
Dart 侧别按 camelCase 取。

实测样例：`q=鲁路修` → 6 条精确命中；`type=game` → 6,178 条。

## 4. 四个必须先知道的事实

**① 默认排序是最老优先，不是最热。** `sort` 缺省值为 `id ASC`，即按入库顺序升序。
后果是首页第一屏永远是**最早导入的那批**，看上去像"数据很旧很难看"，其实不是 bug。
首页/列表页请显式传 `sort=rating` 或 `sort=year`。

**② 封面现在基本拿不到图。** 原因两处叠加：回填进度约 2%（热度降序、先补最热的）；
封面回源白名单尚未重启生效。两个都由后端侧处理，客户端按"无图占位"实现即可——
**这正是最终形态需要的三态兜底，不是临时方案**。

**③ `total` 会持续变化。** 导入进行中，总量从 4 万涨到 55.8 万。不要写死条数，
不要对"第 N 页第 M 条是某作品"做断言——翻页内容会随数据增长漂移。

**④ 元数据有缺口，属上游数据本身缺失。** title/tags 100%、summary 84%、
release_year 91%、**rating 34–36%**、封面当前约 2%。
所以 `sort=rating` 会看到大量 10.0 并列、很多作品无评分，不是排序坏了。

## 5. 联调固定样本

数据在增长，但**已入库记录的 `work_id` 与内容稳定**（导入是幂等 upsert，不会重排）。
用这几条做 golden path 与边界态：

| 用途 | work_id | 内容 |
| --- | --- | --- |
| 完整数据（详情页主路径） | `W-e70201dhttf5ayr` | Code Geass 反叛的鲁路修R2，2008，简介标签齐全 |
| 无简介（详情页空态） | `W-205m6bc2xdqv1kr` | 銀河英雄伝説 (2) 野望篇，`summary` 为空、11 个标签 |
| 标签为空（相关推荐空态） | `W-jt14p67nwkqv1sr` | ポピュラスDS，`tags=[]`，`related` 返回 `basis_tags=[]` 与空 items |
| 游戏类型 | `W-rbgrnwmnd5jrwrr` | 极道车魂2，2000 |
| 小说类型 | `W-ejdysmw28a7zvs0` | 神々の山嶺 (下)，1997 |

## 6. 契约层面的既有约定（别踩）

- 详情命中直接返回作品对象，**不套 `data`**；错误信封是 `{code, message}`。
- 作品不存在返回 **404**；`related` 无同标签时返回**空 items，不是 404**。
- 客户端只调后端 `/api/**`，**绝不直连上游网站**；封面统一走
  `http://154.8.194.198:8080/api/covers/{work_id}`。

## 7. 后端侧待办（不占用客户端时间）

| 事项 | 时机 |
| --- | --- |
| 封面白名单改为下标形式注入（`app.cover.allowed-hosts` 是 List，逗号串不生效） | 全量导入结束后随重启一起做 |
| 全量导入完成（`total` 应达 557,847） | 预计次日傍晚 |
| 登录/收藏接口实现（阶段 2） | 独立排期，不阻塞客户端当前开发 |

3 条上古测试样本已于 2026-10-27 23:58 从生产库清除（原 `id=1,2,3`，均 `source=otaku_site`，
仓库内无对应种子，删除不影响任何迁移），首页第一屏现已是最早导入的真实作品。

## 8. 自查命令

```bash
# 当前数据量
curl -s "http://154.8.194.198:8080/api/works?page=1&page_size=1" | head -c 200

# 搜索是否正常（应返回 6 条）
curl -s "http://154.8.194.198:8080/api/works?q=%E9%B2%81%E8%B7%AF%E4%BF%AE&page=1&page_size=5"

# 详情
curl -s "http://154.8.194.198:8080/api/works/W-e70201dhttf5ayr"
```

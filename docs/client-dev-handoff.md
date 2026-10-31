# 客户端对接现状（全量数据导入期间）

给客户端开发的对接说明。**结论：浏览、搜索、登录、收藏现在就能开发联调，不需要等数据灌完**；
封面暂不可用，按占位处理。

本文所有结论均于 **2026-10-28 00:05 对开发后端复测**，不是设计稿推断。
上一版写于 10-27 23:50，其样本表已由 #227 更正。本次补测更正的是：
**元数据完整率、封面可用率、总量与导入速率**（§4），以及
**两条"端点通但零数据"的接口**、`/api/tags`、`tags` 与 `year` 两个此前漏列的参数（§2、§3）。

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
| `GET /api/works/{work_id}` 详情 | 可用 | 200，12 字段；`summary`/`tags`/`release_year` 均可能为 `null`。**契约已于 2026-10-28 扩到 16 字段**（+`title_original`/`aliases`/`media`/`episodes`），线上仍是 12，待后端实现后按本文矩阵复测 |
| `GET /api/works/{work_id}/related` 同标签推荐 | 可用 | 200，约 0.15s，返回 `basis_tags` |
| `GET /api/tags` 标签词表 | 可用 | 200，2,000 个标签带 `count`，支持 `type` 过滤；约 0.4s |
| `GET /api/schedule` 新番档期 | 端点通、**无数据** | 200，但八个 weekday 组全空、`seasons: []` |
| `GET /api/articles` 资讯 | 端点通、**无数据** | 200，`total: 0`；`/categories` 返回 `[]` |
| `GET /api/covers/{work_id}` 封面 | **基本 404** | 连 `cover_url` 非空的记录取封面也 404 |
| `POST /api/auth/login` 平台账号登录 | 可用 | 401（凭据错）——端点存在 |
| `GET /api/auth/me` 当前用户 | 可用 | 401（未登录）——端点存在 |
| `GET/PUT/PATCH/DELETE /api/me/collections` 收藏 | 可用 | 401（未登录）——端点存在 |
| `POST /api/auth/site-login` 网站账号登录 | **未实现** | 404（阶段 2） |

**登录与收藏已经可用**，用的是平台账号（定位 §4 里的过渡形态）。客户端现有的
`auth_remote_data_source.dart` 打的就是 `/api/auth/login` 与 `/api/me/collections`，
可以真机联调，**不需要 mock**。

只有**网站账号登录**（`/api/auth/site-login`，阶段 2 的令牌交换代理）尚未实现——
「用网站在 Otaku 的同一套账号登录」这条路还不能联调，但平台账号能登、收藏能读写。

> 判断端点是否存在，看 **401/400 与 404 的区别**：401 说明路由存在、只缺凭据。
> 上一版误判为"不存在"，是因为探了 `/api/me`、`/api/collections` 这两个不存在的路径
> （真实路径是 `/api/auth/me`、`/api/me/collections`）。

## 3. 参数速查

列表接口 `GET /api/works`：

| 参数 | 取值 | 说明 |
| --- | --- | --- |
| `q` | 关键词 | 标题搜索。**注意参数名是 `q`**，不是 `keyword` |
| `type` | `anime` / `comic` / `game` / `novel` | 作品类型。**是 `comic` 不是 `manga`**，传错返回 400 |
| `tag` | 标签名 | 单标签精确匹配，**已废弃**，新代码别用 |
| `tags` | 逗号分隔，最多 10 个 | 多标签 **AND**。与 `tag` 同传返回 400 |
| `sort` | `id` / `rating` / `year` | 默认 `id`；非法值返回 400 |
| `min_rating` | 0–10 | 评分下限；无评分一律排除；越界返回 400 |
| `year` | 1900–2100 | **年份等值筛选**（不是排序）；无年份的会被排除 |
| `page` | 从 **1** 开始 | 不是 0-based |
| `page_size` | 默认 20，上限 50 | 超 50 静默截到 50；传 0 回落 20 |

响应为 `{page, page_size, total, total_pages, items}`。

**所有 JSON 字段统一 snake_case**（`work_id`、`cover_url`、`release_year`、`basis_tags`），
Dart 侧别按 camelCase 取。

实测样例：`q=鲁路修` → 10 条精确命中（23:50 时是 6 条、00:02 时 7 条，同一关键词 15 分钟涨了 4 条）；
`type=game` → 6,527 条（同样在涨，别写死）。

## 4. 四个必须先知道的事实

**① 默认排序是最老优先，不是最热。** `sort` 缺省值为 `id ASC`，即按入库顺序升序。
后果是首页第一屏永远是**最早导入的那批**，看上去像"数据很旧很难看"，其实不是 bug。
首页/列表页请显式传 `sort=rating` 或 `sort=year`。

**② 封面现在基本拿不到图。** 三件事叠加：`cover_url` 本身只有约 **3.5%** 非空
（随机 600 条抽样；且分区间极不均匀，前段约 19%、中段 0%）、回填仍在进行、
封面回源白名单尚未重启生效——**即使 `cover_url` 非空，`/api/covers/{work_id}` 实测仍 404**。
后两个原因都在后端侧处理，客户端按"无图占位"实现即可——
**这正是最终形态需要的三态兜底，不是临时方案**。

**③ `total` 会持续变化。** 导入进行中。2026-10-28 00:05 实测 **45,174 条**，
速率约 **389 条/分钟**（60 秒窗口实增）；全量目标 557,847，还差约 51 万。
不要写死条数，不要对"第 N 页第 M 条是某作品"做断言——翻页内容会随数据增长漂移。
连搜索命中数都会变：`q=鲁路修` 23:50 是 6 条，00:05 已是 10 条。

**④ 元数据有缺口，属上游数据本身缺失，且新导入的行更缺。** 随机 600 条抽样：
title 100%、release_year 97.3%、tags 78.5%、**rating 74.7%**、封面 3.5%。
但完整率**随入库批次骤降**：前段（老批次，已回填）rating 约 98%、tags 约 99%；
尾段（最新导入）rating 约 44%、tags 约 41%。所以别把某个百分比当固定前提去设计空态
（旧版写的「rating 34–36%」是当时的单点值，现已不成立）。
`sort=rating` 的可见效果是：评分恰为 10.0 的有 **241 条**，前面整整 50 条全是 10.0，
往下翻才见 9.x——不是排序坏了。

## 5. 联调固定样本

数据在增长，但**已入库记录的 `work_id` 与内容稳定**（导入是幂等 upsert，不会重排）。
用这几条做 golden path 与边界态：

| 用途 | work_id | 内容 |
| --- | --- | --- |
| 完整数据（详情页主路径） | `W-e70201dhttf5ayr` | Code Geass 反叛的鲁路修R2，2008，简介标签齐全 |
| 无简介（详情页空态） | `W-205m6bc2xdqv1kr` | 銀河英雄伝説 (2) 野望篇，`summary` 为空、11 个标签 |
| 标签为空（相关推荐空态） | `W-jt14p67nwkqv1sr` | ポピュラスDS，`tags=[]`，`related` 返回 `basis_tags=[]` 与空 items |
| 无评分（评分空态） | `W-58s8x2m8xga13w0` | 恋をするには遠すぎて，2010，`main_rating: null`，标签 2 |
| 无年份（年份不渲染） | `W-kvh0wdebpe6wvzr` | The Underside，`release_year: null`，简介 1,125 字 |
| 全字段缺失（最狠的空态） | `W-nrx12y6f7ze6p3g` | 瑞克和莫蒂 第六季，tags/rating/summary/year **全 null**，仅 `cover_url` 非空 |
| 游戏类型 | `W-rbgrnwmnd5jrwrr` | 极道车魂2，2000 |
| 小说类型 | `W-ejdysmw28a7zvs0` | 神々の山嶺 (下)，1997 |

上表 2026-10-28 00:05 逐条 `GET /api/works/{id}` 验证均为 **200**；两个空态样本的
`related` 也一并验过（`W-jt14p67nwkqv1sr` 的 `related` 是空 items 而非 404）。

## 6. 契约层面的既有约定（别踩）

- 详情命中直接返回作品对象，**不套 `data`**；错误信封是 `{code, message}`。
- 作品不存在返回 **404**；`related` 无同标签时返回**空 items，不是 404**。
- 客户端只调后端 `/api/**`，**绝不直连上游网站**；封面统一走
  `http://154.8.194.198:8080/api/covers/{work_id}`。

## 7. 后端侧待办（不占用客户端时间）

| 事项 | 时机 |
| --- | --- |
| ~~封面白名单改下标注入~~ 已排除这个猜测：逗号串能正常绑定到 `List`（`CoverWhitelistBindingTest` 钉住）。10-29 的封面故障是配置缩进错位，已修并有结构测试 | 已完成 |
| 全量导入完成（`total` 应达 557,847；00:05 实测 45,174，约 389 条/分钟） | 预计次日傍晚 |
| 网站账号登录（`/api/auth/site-login`）实现（阶段 2） | 独立排期，不阻塞客户端当前开发 |
| 补 `/api/articles` 与 `/api/schedule` 的数据（两条端点通但现在零条） | 全量导入结束后 |

3 条上古测试样本已于 2026-10-27 23:58 从生产库清除（原 `id=1,2,3`，均 `source=otaku_site`，
仓库内无对应种子，删除不影响任何迁移），首页第一屏现已是最早导入的真实作品。

## 8. 自查命令

```bash
# 当前数据量
curl -s "http://154.8.194.198:8080/api/works?page=1&page_size=1" | head -c 200

# 搜索是否正常（当前 10 条；命中数会随导入变化，别断言固定条数）
curl -s "http://154.8.194.198:8080/api/works?q=%E9%B2%81%E8%B7%AF%E4%BF%AE&page=1&page_size=5"

# 详情（主路径样本）
curl -s "http://154.8.194.198:8080/api/works/W-e70201dhttf5ayr"

# 边界态样本是否还在（应全为 200，出现 404 说明又被清理了，回头改 §5）
for id in W-205m6bc2xdqv1kr W-jt14p67nwkqv1sr W-58s8x2m8xga13w0 \
          W-kvh0wdebpe6wvzr W-nrx12y6f7ze6p3g; do
  curl -s -o /dev/null -w "$id %{http_code}\n" "http://154.8.194.198:8080/api/works/$id"
done
```

## 9. 社区接口（评论 / 点评，2026-10-30 全量上线）

作品页底部两个 tab，**两套接口、两张表，不要互相转换**：

| | 评论 | 点评 |
|---|---|---|
| 语义 | 讨论流，可多条、可回复 | 对作品的评价，一人一条 |
| 打分 | 无 | 1–10，可只打分或只写文字 |
| 端点 | `/api/works/{id}/comments` | `/api/works/{id}/reviews` |
| 未开启社区 | 整块不渲染，跳来源站原页 | 同左 |

进页面先查 `GET /api/site/features`：`ugc_enabled=false` 就跳原页，不要渲染空评论区。

### 9.1 评论：一次请求拿到「楼层 + 前 3 条回复」

`GET /api/works/{work_id}/comments` 的 `items` 是**顶层评论**：

- `reply_count`：该楼层已发布的回复总数；
- `replies`：最早 3 条预览（对话顺序）；
- `total` **只算顶层**——别拿它当「评论 + 回复」的总数。

渲染：楼层下直接铺 `replies`；`reply_count > 3` 时显示「查看全部 N 条回复」，
点开调 `GET /api/works/{work_id}/comments/{comment_id}/replies`（分页，最早在前）。

### 9.2 发评论 / 回复

`POST /api/me/comments`，body `{work_id, body, parent_id?}`。

`parent_id` 为空 = 顶层评论；有值 = 回复那条**顶层评论**。只支持一层，
回复一条回复会 `400`（这不是 bug，是设计：两层足够「评论 + 追评」）。

### 9.3 编辑 / 删除

- `PATCH /api/me/comments/{id}` `{body}`：只有正文可改。**响应里顶层评论的 `replies` 是空数组**——
  请只替换这一条本身，不要整条覆盖成「零回复」；
- 先审后发的站点，编辑后会回到 `pending`（重新审核），提示「已提交，审核后显示」；
- `DELETE /api/me/comments/{id}` 幂等 `204`；删顶层会**连带隐藏该楼层的回复**（楼层撤回语义，
  行仍保留，站主导出能看到）。

### 9.4 点评：三个数字别混用

`GET /api/works/{work_id}/reviews/summary`：

| 字段 | 含义 | 用法 |
|---|---|---|
| `total` | 点评条数（**含只写文字不打分的**） | 「N 人点评」 |
| `rated` | 其中打了分的 | 「N 人打分」 |
| `average` | 只对打了分的求均值，**可为 null** | 没有打分时显示「暂无评分」，**不要显示 0** |

`distribution` 只含有数据的分数（不补 0），可直接画柱子。

**与作品自带的 `main_rating`（来源站聚合分）是两套口径**：并列展示、各自标注来源，
不要相加、平均或互相覆盖。

发表：`POST /api/me/reviews` `{work_id, rating?, body?}`，两者至少一项。
重复提交 → **`409 REVIEW_EXISTS`**，引导去编辑原点评，不要弹「失败」。

编辑：`PATCH /api/me/reviews/{id}`，**省略的字段沿用原值**——只改评分不会清空正文。

### 9.5 错误码速查

| HTTP | code | 客户端该做什么 |
|---|---|---|
| 400 | `CONTENT_REJECTED` | 机器审核判为不合规（**未落库**）：提示「修改后再发」，把 `message` 里的理由带上；改完可直接重发，不用刷新列表 |
| 403 | `FORBIDDEN` | 「只能操作自己的内容」或「本站未开启社区」 |
| 404 | `COMMENT_NOT_FOUND` / `REVIEW_NOT_FOUND` | 内容已删或不存在，刷新列表 |
| 409 | `REVIEW_EXISTS` | 引导编辑原点评 |
| 429 | `RATE_LIMITED` | 「发言太快」，按 `Retry-After` 提示 |

### 9.6 两个容易踩的

- `author` 对**已注销账号**显示「已注销用户」——不要用它做用户跳转；
- `status` 只在你刚发的那条上可能是 `pending`（先审后发）；公开列表里永远是 `published`。

# W1.4 · 真实数据联调记录（桌面侧）

> 状态：**服务器侧已验证；客户端渲染仍待人工走查**（本机无屏幕采集手段，走查清单见 §5）。
>
> 主责：@riceyu02（W1）｜日期：2026-10-25
>
> 目的：W1.4「自动化双端一致性已通过，真机未覆盖」里的**桌面侧真实数据**部分。
> 自动化测试跑的是 Mock 与假数据源；这一份把「连真后端、真库」的证据补上。

---

## 1. 环境与复现（本机，Windows）

```bash
# ① MySQL（3310，datadir 在 D:/tmp-otaku-mysql）
#    ⚠️ 必须用后台任务方式起：shell 里的 `&` 会被沙箱回收，端口起来又消失
cd /d/mysql && ./bin/mysqld --port=3310 --datadir=D:/tmp-otaku-mysql --console

# ② 后端（8082）
cd backend-java && env -u SERVER__PORT SERVER_PORT=8082 DB_PORT=3310 DB_USER=root \
  DB_PASSWORD= OTAKU_INTERNAL_TOKEN=dev-token ./mvnw spring-boot:run

# ③ 客户端连真后端（桌面）
cd app-client && flutter run -d windows \
  --dart-define=USE_MOCK=false \
  --dart-define=API_BASE_URL=http://127.0.0.1:8082
```

`USE_MOCK=false` 之前不传的话，跑起来全是演示数据——桌面走查布局可以，
**真实数据渲染（空态 / 长标题 / 无评分沉底）必须带上它再走一遍**。

---

## 2. 联调时修掉的一个环境问题（值得记）

首启动失败：Flyway 报 `Detected resolved migration not applied to database: 7`。

原因：这个 datadir 是 merge train 演练时的产物——**V8（schedule）被应用了，V7（work_tag）没有**，
Flyway 校验不过。处理：

1. 删掉 `flyway_schema_history` 里 version='8' 的行（`schedule` 表本身保留）；
2. 手动执行 `V7__work_tag_filter.sql`（幂等：`CREATE TABLE IF NOT EXISTS` + `INSERT IGNORE`，
   回填 1,451,784 行）；
3. 重启，Flyway 自行补齐 V7/V8/V9 记录。

⚠️ 教训：**库的迁移历史可能和代码不同步**（演练分支 outOfOrder 执行过）。
本地库起不来先查 `flyway_schema_history`，别急着改代码。

---

## 3. 契约行为验证（真实后端，2026-10-25）

| 查询 | 结果 | 结论 |
|---|---|---|
| `GET /api/works?page_size=5` | `total=571660`，字段齐（含 `source`、`main_rating.scale`） | 与库内条数一致 |
| `GET /api/works?sort=rating` | 首屏即出现 `cover_url=null` 的条目 | 封面缺口在真实排序里就能看到，D1 占位不是纸面场景 |
| `GET /api/works?tag=科幻` | `total=5753`，返回带该标签的作品 | 标签反查表（V7）生效 |
| `GET /api/works?tag=不存在的标签xyz` | **`total=0` + 空数组，HTTP 200** | 契约语义正确：「这个标签没数据」不是错误 |
| `GET /api/schedule` | `season=202610`，27 个季度，按周几分组 | 档期可用 |
| `GET /api/works/{id}` 详情 | — | 未逐条验（本次重点是列表与档期） |

---

## 4. 真实数据的边界分布（客户端呈现策略的输入）

| 维度 | 条数 | 占比 | 对客户端意味着什么 |
|---|---|---|---|
| 无评分 `rating_value IS NULL` | 364,728 | 63.8% | **D2 的「沉底 + 标注」是主路径，不是边缘情况**——默认排序下三分之二的条目没有评分 |
| 无封面 `cover_source_url` 空 | 556,404 | 97.3% | D1 三态占位是常态；封面加载失败的降级路径会被频繁走到 |
| 无标签 `tags` 空 | 312,833 | 54.7% | 标签 chips 不显示；标签筛选入口对半数作品无意义 |
| 标题 > 40 字符 | 15,985 | 2.8% | **长标题是真实风险**：实测最长 146 字符（`W-hqhg0j51mv1trcg`，英文长句）。卡片标题必须能截断而不溢出 |

> 数字与 W3 体检报告（`data-quality-report.md`）口径一致；「标题 > 40 字符」是本次新测的维度，
> 之前的体检没有覆盖标题长度——而它直接决定卡片会不会溢出。

---

## 5. 客户端人工走查清单（需要人 + 屏幕，本机做不了）

按 §1 的命令起环境，然后逐条看：

| # | 场景 | 怎么看 | 期望 | 自动化覆盖 |
|---|---|---|---|---|
| 1 | 长标题 | 打开 `W-hqhg0j51mv1trcg`（146 字符）或列表往下翻到长标题条目 | 卡片标题截断为两行左右，不溢出、不撑破网格 | ✅ 列表 + 详情页各一条 |
| 2 | 无评分沉底 | 设置里把排序切成「评分」，看首屏之后 | 无评分条目沉底且有可解释标注，不像「坏了」 | ✅ 说明条与逐条标注（有评分时不出现） |
| 3 | 封面占位 | 列表首屏（97% 无封面） | 三态区分：加载中 / 本来没有 / 加载失败，不裂图 | ⚠️ 只覆盖「本来没有」这一态 |
| 4 | 未知标签 | 手动构造 `?tag=xyz`（或用任意不存在标签） | 空状态文案说清「这个标签没有数据」，而不是「加载失败」 | ✅ 空态文案 + 清除出口 |
| 5 | 档期页 | 侧栏「新番」 | 按周几分组、季度切换、`work_id` 为空白的条目只展示不跳转 | ⚠️ 只覆盖按周几分组 |
| 6 | 错误态 | 关掉后端再刷新 | 明确错误提示，不无限转圈，不把错误显示成空列表 | ✅ 错误提示 + 无骨架屏 + 无转圈 |

**「✅」= 已有自动化断言钉住**（`app-client/test/real_data_render_test.dart`，
数据是从真后端拉下来存下的响应原文，见 §7）。
**「⚠️」= 只覆盖了一部分，剩下的仍要人看**：
封面三态里的「加载中 / 加载失败」、档期页的季度切换与空 `work_id` 条目。

跑完把结果追加到本文档 §6（谁、什么时候、看了哪几条、发现什么问题）——
按章程 §4「完成时带着证据来」，这六条看过并记录，W1.4 的桌面侧才算收口；
Android 真机那半仍待设备。

---

## 6. 走查记录（待填）

_（尚未有人跑过。第一条应该是本机 Windows 桌面 + 真实数据。）_

---

## 7. 自动化 fixture 从哪来（要重新生成时看这节）

`app-client/test/fixtures/real_*.json` 是**真后端的响应原文**，不是手写的假对象。
这样测的是「真实数据形状 → 模型解析 → 界面渲染」整条链，而不是「我认为数据长什么样」。

起好 §1 的 ①② 之后，在 `app-client/` 下执行：

```bash
B=http://127.0.0.1:8082
curl -s "$B/api/works?page_size=50"                     -o test/fixtures/real_works_default.json
curl -s "$B/api/works?sort=rating&page_size=50"          -o test/fixtures/real_works_by_rating.json
curl -s "$B/api/works?tag=zzz-not-exist-tag&page_size=5" -o test/fixtures/real_works_unknown_tag.json
curl -s "$B/api/schedule"                               -o test/fixtures/real_schedule.json

# 评分排序的「最后一条全无评分」那一页：先查总数再取末页
#   （这一页是「无评分沉底」的断言依据）
T=$(curl -s "$B/api/works?tag=游戏&page_size=1" | python -c "import sys,json;print(json.load(sys.stdin)['total'])")
curl -s "$B/api/works?tag=游戏&sort=rating&page=$(( (T+49)/50 ))&page_size=50" \
     -o test/fixtures/real_works_rating_tail.json

# 最长标题那条（库里最长 146 字符）：先由 SQL 定位 id，再取列表与详情
curl -s "$B/api/works?q=If%20Letters%20Had%20Pants&page_size=5" -o test/fixtures/real_works_long_title.json
curl -s "$B/api/works/<那个 id>"                          -o test/fixtures/real_work_detail_long.json
```

⚠️ **fixture 与库强绑定**：库里的数据变了（比如标签改名、评分重灌），
这些断言可能就不成立了。改了数据之后要重新生成并跑一遍
`flutter test test/real_data_render_test.dart`。
`real_work_detail_long.json` 里的标题长度 146 是当前库的最长值，
库里若出现更长的标题，测试不会自动知道——那是新的边界，值得再补一条。


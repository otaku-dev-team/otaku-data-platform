# W4 · 第二站接入实测（VNDB）

> 日期：2026-10-24 ｜ 主责：@pyxz0 ｜ 归口：[Issue #155](https://github.com/otaku-dev-team/otaku-data-platform/issues/155)
> **结论**：G2 在后端这一层**成立**——接一个真实的新站，后端 **0 行代码改动**。
> 但同时暴露一个只有真接第二站才会出现的问题：**评分尺度不参与排序与过滤**，会让排行榜和 `min_rating` 静默错位。

---

## 1. 一句话

用 VNDB 的公开只读 API 接了 30 条真实数据：列表 / 详情 / 标签筛选 / 封面代理全部可用，
改动只有「一份字段映射 + 一个封面白名单条目」。**但两个来源的评分尺度不同（0–100 vs 0–10）时，
`sort=rating` 与 `min_rating` 会给出语义错误的答案。**

---

## 2. 为什么选 VNDB

Issue #155 里给出的三个条件：公开只读、条目型、能落进现有 `work_type`。实测了五个候选：

| 候选 | 本机可达性 | 判断 |
|---|---|---|
| Bangumi API（`api.bgm.tv`） | 超时 | 且 `bangumi` 已是库里现有来源，不算"第二站" |
| Jikan（MyAnimeList） | 超时 | 不可达 |
| OpenLibrary | 超时 | 不可达 |
| Steam store API | 超时 | 不可达 |
| 萌娘百科 MediaWiki API | **200** | 可用，但条目是维基词条，字段映射牵强 |
| **VNDB（`api.vndb.org/kana/vn`）** | **200** | **选中** |

选 VNDB 的三条理由：

1. **公开只读、无需鉴权**——不碰登录后内容、不用任何凭据（铁律 1）；
2. **字段能直接映射**：`title` / `image.url` / `description` / `rating` / `released` / `tags` 全都有；
3. **类型落在现有四值内**（VN → `game`），不需要为了验证去动 `work_type` 枚举（那是红线）。

> 注：VNDB 全称 Visual Novel Database，条目是视觉小说，属游戏类。「条目型」这里是成立的，
> 但**不是**通用化提案里说的图书 / 电商 / 论坛——那些要先改 `work_type`，见 §7。

---

## 3. 抓到了什么（30 条，单次请求）

按评分降序取 Top 30（`rating >= 70`）：

| 字段 | 覆盖率 | 备注 |
|---|---|---|
| `title` | 30 / 30 | 英文/罗马字标题 |
| `image.url`（封面） | **30 / 30** | 比首站好得多（bangumi 档案 0% 有封面） |
| `description`（简介） | 29 / 30 | 含 BBCode（`[url=…]`），需清洗 |
| `rating` | 30 / 30 | **尺度 0–100**，不是 0–10 |
| `released` | 30 / 30 | 2004–2026 |
| `tags` | 30 / 30 | 英文标签，取前 5 个 |

30 条一次导入耗时 **0.39 秒**，`rejected=0`。

---

## 4. G2 的答案：到底改了什么

| 类别 | 改动 | 量 |
|---|---|---|
| 后端 Java 代码 | **0 行** | 未动 |
| 接口②③④ / 契约 | **0 改动** | 未动 |
| 客户端 | **0 改动** | 未动 |
| 配置 | `app.cover.allowed-hosts` 增加 `t.vndb.org:443` | 1 行 |
| 适配 | 抓取 + 字段映射脚本 | 约 40 行 Python |

**这就是 G2 想要的形态：新站 = 一份映射 + 一个白名单条目。**

不过要说清楚：那 40 行是**一次性探针**，不是生产适配器。真适配器要进 `sync-python`，
复用它的限流、重试、失败记账（见 §7）。

---

## 5. 真问题：评分尺度被存下来，却不参与比较

契约里有 `rating_scale` 字段，导入校验也只看「`scale` 是不是 `0-10`」来决定要不要做范围检查。
**但排序与过滤只比较 `rating_value` 这个数值，不看尺度。**

按原始值（0–100）导入 30 条后：

| 查询 | 实际结果 | 应该是 |
|---|---|---|
| `sort=rating` 前 5 | 全部是 VNDB：90.6 / 90.2 / 90.2 / 90.2 / 89.9，首站 9.0 分的条目被压到后面 | 两个来源按同一尺度可比 |
| `min_rating=9`（意图：≥ 9/10） | **31 条** | 只有真正 ≥ 9 分的那几条 |

这不是显示问题，是**语义错误**：排行榜把 90.6 和 9.0 放在一起比。

按归一映射（÷10，存 0–10）重导后：

| 项 | 结果 |
|---|---|
| 导入计数 | `updated=30`（走的是更新路径，不是重复插入） |
| `work_id` 稳定性 | `W-npxz1465m4xc1br` 前后一致 |
| `sort=rating` 前 5 | 9.06 / 9.02 / 9.02 / 9.02 / 首站 9.00 —— 恢复正常 |
| `min_rating=9` | 31 条 → **5 条**，语义恢复 |

### 要拍板（三选一）

| 方案 | 做法 | 代价 |
|---|---|---|
| **A 适配器归一**（本次做法） | 第二站适配器把评分换算到 0–10 再提交，契约不动 | 换算规则是**隐式约定**，写错了没人拦 |
| **B 契约只收 0–10** | `rating_scale != "0-10"` 一律 `RATING_OUT_OF_SCALE` | 接 0–100 的站必须换算，但**错就报错**，不会静默污染排序 |
| **C 比较时带尺度** | `ORDER BY rating_value / scale` 之类 | 索引失效，57 万条上不可行 |

**倾向 B**：一条校验就能把「静默错」变成「显式错」，成本最小，且不引入新概念。
代价是第二站的适配器必须做换算——但那本来就该做，只是从「约定」变成「强制」。

---

## 6. 封面代理：接新站必须加白名单

| 步骤 | 结果 |
|---|---|
| 首次取图（回源 `t.vndb.org`） | `200` / `image/jpeg` / 178 KB / 16.7 s |
| 二次取图 | **12 ms**，字节与首次一致（本地缓存生效） |
| 白名单外的封面（`example.com`） | **404**，符合预期 |

接第二站时这一步不能忘，否则封面会全 404。`#156` 已把白名单语义改成 fail-closed：
漏配表现为「封面全 404 + WARN」，而不是静默放行任意地址。

---

## 7. 还缺什么（不属于本次验证）

| 项 | 归属 | 说明 |
|---|---|---|
| 真适配器 | zm / sync-python | 本次用一次性脚本证明可行，**没有动他的模块**；生产版要复用的限流、重试、失败记账都在他那边 |
| `work_type` 四值枚举 | 后端 + 契约 | VNDB 能落 `game` 是运气；接图书 / 电商 / 论坛要先改契约（红线） |
| 客户端品牌配置 | riceyu02 / W1 | 应用名 / 图标 / 包名按站独立 |
| 标签词表 | — | VNDB 是英文标签、首站是中文，**跨源不互通**；这符合「各站独立」的定位，不算缺陷 |

---

## 8. 复现

```bash
# 1) 抓 30 条（单次请求，尊重来源站，不批量遍历）
curl -s -X POST https://api.vndb.org/kana/vn \
  -H 'Content-Type: application/json' \
  -H 'User-Agent: otaku-data-platform/0.1.0 (W4 second-site probe)' \
  -d '{"filters":["rating",">=",70],
       "fields":"id,title,image.url,description,rating,released,tags.name",
       "sort":"rating","reverse":true,"results":30}'

# 2) 映射为接口② 载荷：source=vndb / work_type=game / rating÷10 / tags 取前 5
# 3) 起后端并放行新站封面 host
APP_COVER_ALLOWED_HOSTS="154.8.194.198:8000,t.vndb.org:443" \
  DB_NAME=otaku_it MYSQL_PORT=3307 SPRING_PROFILES_ACTIVE=local ./mvnw spring-boot:run

# 4) 导入并验证
curl -X POST $BASE/internal/import/batches -H "X-Internal-Token: …" -d @w4-norm.json
curl "$BASE/api/works?sort=rating&page_size=5"
curl "$BASE/api/works?min_rating=9"
curl -i "$BASE/api/covers/<work_id>"
```

---

## 9. 未做 / 不确定

- **只接了 30 条**，没有做全量或分页遍历；VNDB 的分页与限流策略没有系统测
- **没有写进 `sync-python`**：真适配器必须走 zm 的框架，否则会绕开限流与失败记账
- **16.7 秒的回源耗时**是本机网络 + 沙箱代理导致，**不代表生产表现**，不要对外引用
- **没有核对 VNDB 的 robots / ToS 细则**：本次是单次只读探测；正式接入前需要确认可接受的使用方式
- **跨源同名的展示**（D3）本次没验：VNDB 标题是英文，与首站中文标题不会撞名，样本里也没有跨源同名对

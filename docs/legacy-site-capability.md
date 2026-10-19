# 旧站能力复用清单

> 检查对象：`http://154.8.194.198:8000`（现有 Otaku 网站，FastAPI，`/openapi.json` 标题为 "Otaku · ACGN 内容平台与接口自动化测试后台"）
> 检查时间：2026-10-20，全部为**只读**请求，未写入任何数据。
> 用途：判断新平台能从旧站直接复用什么、需要加工什么、以及哪些必须自建。

## 一句话结论

旧站**不止是五个字段的内容库**——它还有可直接访问的封面图、可用的标签筛选、放送表，以及一整套账号与收藏体系。其中**封面和标签此前被判定为"不存在"，这个结论是错的**，需要修正契约草案（见文末）。账号与收藏属于旧站自有业务，不复用。

## 一、可直接复用

| 能力 | 入口 | 实测结果 | 复用方式 |
| --- | --- | --- | --- |
| 内容列表 | `GET /api/contents?type=anime` | 200，anime 7894 条，**6.2 MB / 13.2 秒**；忽略 `page`/`page_size`，一次返回全量 | Python 同步作业一次拉全量后自行分批 |
| 内容详情 | `GET /api/contents/{id}` | 200，字段仅 `id` `title` `type` `summary` `rating` | 与列表一致，无需逐个详情拉取 |
| 搜索（真分页） | `GET /api/contents/search?q=&page=&page_size=` | 200，返回 `{total, page, page_size, total_pages, items}`，分页**真实生效** | 需要分页场景走搜索接口，不走列表 |
| **封面图** | `GET /media/full/cover_{N}.jpg`、`GET /media/thumb/cover_{N}.jpg` | 200，可直连下载。full 约 95 KB，thumb 约 26–32 KB | 见第二节，需先拿到 N |
| 健康检查 | `GET /api/health` | `{"status":"ok","service":"acgn-test-platform"}` | 同步前的存活探测 |
| 放送表 | `GET /api/schedule`、`/api/schedule/seasons` | 4 个季度（202610/202607/202604/202601）共 201 条；含 `title_cn` `title_jp` `weekday` `image_url` `source_url` `last_synced_at` | 若首期做"新番时间表"可直接用 |
| 标签筛选 | `GET /api/contents?tag=热血` | 生效。热血 281 / 搞笑 964 / 恋爱 511 / 科幻 402 / 校园 341 条 | 可按标签取子集，但不返回每条的标签 |

## 二、需要加工才能用

封面和标签都真实存在，但**没有直接的 API 暴露**，抓取成本是决策关键。

**封面映射**：封面文件名里的数字 `N` **不等于** `content_id`（content 476 对应 `cover_313852.jpg`；而 `cover_476.jpg` 是另一个作品的文件，会错误命中）。可靠获取方式有两种，均已实测：

- **列表页 HTML**：`GET /contents?type=anime&page=N` 每页 20 条，可稳定提取 `(content_id, cover_文件名)` 配对，实测命中 20/20，与详情页交叉校验一致。anime 7894 条约 **395 页**。
- **详情页 HTML**：`GET /contents/{id}` 中 `/media/full/` 恰好出现 1 次，位置稳定，可逐条补齐。

两个坑要记：文件扩展名是 `.jpg` 但**实际内容是 WebP**（`Content-Type: image/webp`，文件头 `RIFF....WEBP`），按扩展名解码会失败；封面 URL 是旧站路径，长期可用性和外链策略需与维护者确认。

**标签还原**：`/api/contents` 的返回体**不含** `tags` 字段，只能用"拿候选标签逐个反查、再归并到条目"的方式重建。标签全集没有枚举接口，成本随标签数量线性增长。

**演职与创作者**：存在 `/cast/{person_id}`、`/creators/{name}` 页面，但只有 HTML、无 JSON API，且详情页里 studio 链接为空。

## 三、不复用

| 项目 | 原因 |
| --- | --- |
| 年份 | `year` 参数存在但无效，`?year=2024` 返回 0 条。旧站没有可用的年份数据 |
| 账号体系 | `/login` `/register` `/verify/email` `/forgot-password` `/admin/*`（邀请码、角色）均为旧站自有实现，未登录访问 `/me` 会 302 到登录页。新平台自建 |
| 收藏 / 状态 / 历史 | `/contents/{id}/favorite`、`/status`、`/me/history` 等均为登录后页面表单提交，**不是 JSON API**。新平台的跨端同步本就要重做，不复用 |
| Persona / LLM 报告 | `/me/persona/*` 属旧站增值功能，与新平台数据层无关 |
| 接口自动化测试后台 | `/api/testcases`、`/api/runs`、`/api/batches` 是旧站的测试平台，与本项目无关 |
| 数据摄取接口 | `POST /api/ingest/subjects` 需 `X-Ingest-Key`，无 key 返回 401。这是**往旧站写**的方向，与我们的同步方向相反 |

## 四、对现有契约草案的冲击

PR #4（`docs/data-contract.md`）中的以下结论**需要修正**：

- 原结论：来源不提供封面、年份、标签，首期三个字段恒为 `null`
- 实测：**封面有、标签有、年份确实没有**
- 影响：`cover_url` 与 `tags` 不再必须恒为 `null`，是否抓取取决于团队决策；`release_year` 维持 `null`

`sync-python` 的清洗逻辑不受影响（它只处理文本与评分）；若决定抓封面，`models.py` 需增加来源字段，`source.py` 需增加 HTML 抓取路径。

## 五、需要团队共同决定

1. **封面抓不抓**：395 页 HTML（仅 anime，全类型约 601 页）换 12012 条封面。收益是客户端不用长期占位，成本是新增一条抓取链路和一份外部资源依赖
2. **标签反不反查**：成本高、收益中等，建议首期搁置，只保留来源筛选能力
3. **放送表纳入首期吗**：数据质量好（含中日双语标题与外链封面），但属于新功能，会扩大首期范围
4. **旧站可用性与配额**：本次只做了单次只读探测，**未做并发与速率压测**，不得假定"无限制"。需向维护者确认：是否长期在线、是否允许批量抓取、有无速率上限、封面能否外链引用
5. **是否请维护者直接补接口**：如果能让旧站新增一个返回封面与标签的 JSON 字段，成本远低于我们抓 HTML

以上第 1、3 项若决定做，应在 `docs/data-contract.md` 定稿前完成，避免二次返工。

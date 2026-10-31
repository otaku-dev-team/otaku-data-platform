# 站点下线演练（2026-10-31）

> **一句话**：`scripts/site-offboarding.sql` 第一次被真跑了一遍。**发现它漏删点评**——
> 承诺写的是「副本按要求删除」，少删一张表就是没兑现。已修，重跑验证通过。

## 1. 为什么必须演练

`product-positioning.md` 的停服态写的是「停止同步 → 客户端下线 → **副本按要求删除** → 数据交还客户」。
数据交还（导出 CSV）做了也验了；「删除副本」自 2026-10-29 起只有一份脚本，**从没执行过**——
没有执行过的删除脚本，和没有备份一样，只是心理安慰。

而且这张表是**后来才加的**：脚本写于 10-29，`ugc_review`（点评）是 10-30 的 V24 才上线。
「先写脚本、后加表」这种顺序，最容易出现「删了评论、忘了点评」。

## 2. 怎么做的（可复现，且不碰生产）

生产库的 UGC 表是空的（还没有真实用户），在线上跑只能证明「脚本能执行」，证明不了「删得干净」。
所以在本地起了一个**只有 schema、没有业务数据**的库：

```bash
# ① 空库 + 跑一遍应用让 Flyway 迁移到最新（V27）
docker run -d --name otaku-drill2-mysql -e MYSQL_ROOT_PASSWORD=drill \
  -e MYSQL_DATABASE=otaku -p 127.0.0.1:3308:3306 mysql:8.0 \
  --character-set-server=utf8mb4 --collation-server=utf8mb4_0900_ai_ci
DB_HOST=127.0.0.1 DB_PORT=3308 DB_NAME=otaku DB_USER=root DB_PASSWORD=drill \
  SERVER_PORT=8082 java -jar backend-java/target/backend-java-0.1.0-SNAPSHOT.jar   # 起来即迁移，然后停掉

# ② 灌两个站点的假数据：drill-a 待下线，drill-b 做对照
#    评论 3（含 1 条回复、1 条已撤回）/ 点评 2 / 举报 1 / 历史审计 1

# ③ 干跑（脚本末尾 p_dry=1）
sed "s/'CHANGE_ME'/'drill-a'/" scripts/site-offboarding.sql | mysql ... otaku

# ④ 对账无误后真删（p_dry=0）
```

## 3. 第一次跑：抓到一个真缺陷

用**当时的**脚本真删 `drill-a` 之后：

| 表 | 删除前 | 删除后 | 期望 |
|---|---|---|---|
| `ugc_comment` | 3 | **0** | 0 ✅ |
| `ugc_report` | 1 | **0** | 0 ✅ |
| `console_audit` | 1 | **2**（保留 1 + 新增 `site.offboard`） | 保留 ✅ |
| **`ugc_review`** | **2** | **2** | **0 ❌** |

点评一条没删。审计里写的还是「删除 UGC 副本 comments=3 reports=1」——**它自己都不知道漏了**。
如果这是真实客户下线，确认函会写「副本已删除」，而库里还躺着这个站的全部点评。

## 4. 修复与复验

`scripts/site-offboarding.sql` 现在：

- 统计与删除都加上 `ugc_review`；
- 审计 detail 变成 `comments=N reviews=M reports=K audits_kept=J`；
- 结果集多一列 `reviews_left`；
- 头注释写明「点评也在这个脚本范围内」，以及建议的执行顺序（**先停站、再删副本**：
  `POST /internal/sites/{key}/suspend` 只封后台不动数据，删副本不可逆，必须有人签过字）。

重灌数据 → 干跑 → 真删，结果：

| 站点 | 评论 | 点评 | 举报 | 审计 |
|---|---|---|---|---|
| `drill-a`（下线） | 3 → **0** | 2 → **0** | 1 → **0** | 1 → **2**（保留 + `site.offboard`） |
| `drill-b`（对照） | 2 → 2 | 1 → 1 | 1 → 1 | 1 → 1 |

审计内容：`删除 UGC 副本 comments=3 reviews=2 reports=1 audits_kept=1`。

**重复执行**也试了：第二次各表计数全 0，仍会再写一条 `comments=0 …` 的审计。
这是**有意**的——它记录的是「有人又执行了一次」，不是「又删了东西」；头注释里写清了，免得下次有人以为脚本出错。

## 5. 第二轮：数据交还也漏了（2026-10-31 晚）

删干净只是那条承诺的**后半句**。完整的是「数据交还客户 → 副本按要求删除」——先交、后删。
于是把前半句也真跑了一遍：站主登录后台，`GET /api/console/ugc/export?status=all`，
然后看导出的 CSV 里到底有什么。

库里当时是 2 条评论（1 条回复、1 条编辑过）、1 条点评（9 分）、1 条举报。

| 导出 | 拿到 | 库里有 | 结论 |
|---|---|---|---|
| `GET /api/console/ugc/export?status=all` | 2 行评论 | 2 条评论 | ✅ |
| 同一接口，再想拿点评 | **没有这个参数** | 1 条点评 | ❌ |
| 同一接口，再想拿举报 | **没有这个参数** | 1 条举报 | ❌ |

导出的 `X-Export-Rows=2`，站主会以为「我的数据就这些」。而删除脚本**三张表都删**。

这就是上一节那个缺陷的镜像：删除侧漏了点评，交还侧也漏了点评与举报。两边都是
「先写代码、后加表」——`ugc_review` 是 10-30 的 V24，导出接口写得更早。
**只修一边没用**：删得干净但没交出去，等于把客户的数据删了。

修法（`type` 参数，缺省仍是评论，老调用方不受影响）：

| 请求 | 文件 | 列（首行） |
|---|---|---|
| `?type=comment`（缺省） | `ugc-<site>-<date>.csv` | comment_id, parent_id, work_id, work_title, author, status, created_at, body |
| `?type=review` | `reviews-<site>-<date>.csv` | review_id, work_id, work_title, author, rating, status, created_at, edited_at, body |
| `?type=report` | `reports-<site>-<date>.csv` | report_id, comment_id, work_id, work_title, reporter, reason, status, created_at |

三份而不是一份：三种行字段天然不同（点评有评分、举报有理由），硬塞一张表站主分不清哪列对哪行；
文件名也不同，三个文件下到同一个目录不会互相覆盖。响应头多了 `X-Export-Kind`。

复验（同一套本地环境，真数据）：

| 请求 | 行数 | 内容核对 |
|---|---|---|
| `type=comment` | 2 | 回复带 `parent_id=1`、编辑过的正文是新的 |
| `type=review` | 1 | `rating=9`、两行正文按 RFC 4180 转义成一个带引号的字段 |
| `type=report` | 1 | `reason` 里的逗号与引号正确转义、`comment_id` 能对回评论 |
| `type=reviews`（拼错） | **400** | 「type 只能是 comment / review / report」——不静默导出评论让人以为拿到了点评 |

### 现在的规矩：三个数字对不上，不许执行删除

确认函里三份导出的条数，必须与 `scripts/site-offboarding.sql` 干跑输出的
`comments` / `reviews` / `reports` **逐项相等**。少一份、或数字不等，说明交还还没做完，
此时删就是数据丢失。这条写进了脚本输出与确认函模板——只写在文档某一节里，执行的人看不到。

## 6. 结论与边界

- 「删除副本」这条承诺现在有**可复现的证据**，确认函模板同步补了点评条数与停站步骤。
- 脚本范围仍然是 **UGC only**（评论 / 回复 / 点评 / 举报）。收藏、账号、设备令牌按合同另行处理——
  混在一个脚本里删，迟早误伤。
- `site` 行**不删**：它是站点注册与审计的锚点，下线用 `suspend`（状态 `suspended`），不是 `DELETE`。
- 生产库这次**一行没动**：演练全程在本地容器里，跑完把容器和假数据一起删掉。
- 交还与删除**现在范围一致**：三张表 `ugc_comment` / `ugc_review` / `ugc_report`，
  导三份、删三张。以后再加表，两处必须同时改——这次两个缺陷都是「只改了一处」。
- 还没验的：客户书面确认（商务流程），以及真实站点第一次下线时的**完整串联**
  （停站 → 导三份 → 对账 → 删 → 确认函签字）。技术侧每一步都单独验过了。

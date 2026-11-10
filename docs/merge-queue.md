# 合并队列与合并后动作清单

> **现用清单。** 每次合并后更新这一份，不再另写。
> **最新批次看 §2 表格**（已到第 46 批，2026-11-09）；头部不再重复写会随时过期的 PR 数 / 分支数。
> 最后更新：2026-11-09 03:45，`main = c33a251`（第 32–34 批**已发版**：b34 / b35；第 44 批客户端**已发 1.1.7**；**第 45–46 批待发版**，其中 #555 是线上故障修复，与 #552 开关同批发 1.1.8；`b31` 及之前也已发版）。
> 历史基线（**已过期，只作留档**）：2026-11-01 01:10、`main = 4789cbf`、第 18 批、开放 PR 4 个。
> **客户端已发 1.1.3 / 1.1.4（内部测试），E9–E14 只剩 E13 域名与 HTTPS；下载托管实测可用，见 §0.5。**
> 合并权条例仍按 [`project-charter.md`](project-charter.md) §3.5：**CI 全绿 + 不碰红线 + 说清楚，谁都能合（含自合）**。

## 0. 一句话

**2026-11-07 20:30 发版（`b34` → `b35`）**：资讯收藏（#377）、账号资料与头像（#378）、
compose 调度池默认对齐（#511）、人物键热修（#512）全部上线。

- **迁移**：V33（#362 人物前缀，9.6 s）/ V34（`article_favorite`）/ V35（`app_user` 资料三列）/
  V36（`people` 前缀补齐 + 两条 `person_id` 索引，3.6 s）；启动 10.8 s、容器 healthy；
- **b34 上线后发现人物页全 404**：V33 只改了 `work_*`，`people.source_id` 还是裸数字；
  b35 用 V36 补齐，并兼容新旧键。热身后 `GET /api/persons/bgm:3818` **46–66 ms**
  （原 140–170 ms，再早 460–570 ms）；
- **冒烟 7/7**；`/api/me/account`、`/api/me/article-favorites` 未登录 401；
  生产实测头像上传输出 `.webp` / `image/webp`；备份已含 `*-avatars.tar.gz`；
- 回滚包：`target/*.jar.bak-b34-20261107T121741Z` / `.bak-b35-20261107T123038Z`；
- **教训**：scp 上传的 `.sh` 会带 CRLF，`#!/usr/bin/env bash\r` 直接跑不起来（`backup.sh` 中过）；
  部署后必须 `sed -i 's/\r$//'` 并 `bash -n` 复核。

**2026-11-06 17:20 发版（`b31`）**：今天合入的 9 个 PR 全部上线——人物页（#462）、我的评论（#459）、
VNDB 评分归一（#464）、405/415（#465）、调度池 4（#469）、导入提交超时 120s（#470）、
阿宅画像（#471）、规则推荐（#472）、资讯↔资讯（#473）。

- **无迁移**：`V1…V32` 早已在库，本次只换 jar；启动 **7.3 s**、容器 healthy；
- **冒烟 7/7 通过**（health / 列表 total=18676 / 详情 / tags / 封面 200 / 内部接口 401 / prometheus 401）；
- **新端点实测**：`POST /api/works` → 405 + `Allow: GET`；`text/plain` → 415（`UNSUPPORTED_MEDIA_TYPE`）；
  `/api/me/profile` 与 `/api/me/recommend` 未登录 → 401；`/api/articles/{id}/related` → 200 有数据；
  `/api/persons/1` → 200（「水樹奈々」+ 参与作品，生产 people 表**不是空的**）。
- 回滚包：`target/backend-java-0.1.0-SNAPSHOT.jar.bak-b31-<时分秒>`。
- **正式域名仍未解决**（#195），对外仍是 `http://154.8.194.198:8080`（无 HTTPS）。

**同日两次补发**（都是人物页上线后才暴露的问题，`#476` / `#477`）：

| 包 | 时间 | 改了什么 | 效果 |
| --- | --- | --- | --- |
| `b32` | 18:17 | `PersonService` 的三条「按 person_id 全表扫」压成一次（两次 COUNT 改为从 credits 推导） | `GET /api/persons/1` **0.46–0.57 s → 0.14–0.17 s** |
| `b33` | 18:25 | `summariesByWorkIds` 不再复用「相关作品」的 `30×4` 截断；计数改按 `works` 算 | `works 120 → 193`、`cast_count 193` 与列表一致 |

> 两个都不是估算出来的：`0.46 s` 是发版后在机器上 curl 到的，`120 vs 193` 是同一份响应里
> 自相矛盾的两个字段。**根治**（person_id 索引）已由 b35 的 V36 补上，热身后 46–66 ms。

**10-31 收盘：后端 UGC 十项全部在线**——评论 / 开关与审核 / 举报与先审后发 / 导出 / 回复 /
留存清理 / 编辑 / 注销 / 点评 / **机器审核接入位**（默认不接入），`V18–V27` 已跑在生产。
同一天还补了两件没人看但真会出事的：**备份恢复演练**（真实 dump，24 表一致）与**巡检告警通道**
（服务器没有 MTA，此前失败只进 syslog）。
10-28 到 10-29 那两天的 71 个提交（后端从「能浏览」到「能承载社区」）仍是这轮的地基：
作品软删、详情富字段与 Staff·声优·制作公司、people 补人、指标端点。

**第 9 批客户端整合（#302）已于 14:30 合入 main**（merge commit `af78b85`）：导航独立栈、设置二级页、
标签面板分组、搜索建议面板、更新包断点续传、外观实验（默认关）、追番提醒下线、封面与标签行。
它 cherry-pick 了 #299 的两个提交（#238 错误分档），**#299 随之关闭并留言说明去向**——
为免同一份改动在 main 上留两遍历史。客户端全量 **391 通过 / 0 失败**。

**当前开放 PR：0 个**（截至 2026-11-07，`gh pr list --state open` 实测为空）。§6 快照里的 #320 / #323 / #325 / #343 与 #362 / #398 均已合入 main；无待收口 PR，无分支阻塞。

在跑的是数据侧长任务：封面回填分片（cron 每 4 小时 4,000 条，
预计 4–5 天，全库封面 48% → 约 85%，见 #288）。**等外部输入只剩一件**：#195 正式域名
（#242 真 ticket 与告警 webhook 均于 2026-11-01 落地，见 §6）。W1 客户端侧要人的活只剩：
**主观观感走查**（动效/配色，清单见 [`w1-real-data-probe.md`](w1-real-data-probe.md) §5.1）
与 **真机登录闭环**（要一个站点测试账号）。原「真机走查 4 项阻塞」里，通知送达与重启重注册
已随追番提醒下线失效，2026-11-01 复核（见 §3 待办）。

**查 PR 先看评论区**：D3 卡过一整天，最后发现 @zhengmin486 早在 #120 的评论里放行了。
「待三人确认」这个标签不一定反映最新讨论进度。

## 0.5 客户端发版状态（2026-10-31 出包，2026-11-01 复核托管）

| 版本 | versionCode | 说明 |
|---|---|---|
| **1.1.4** | 6 | 当前线上清单指向它。与 1.1.3 功能相同，**纯为验证应用内更新链路** |
| 1.1.3 | 5 | 首个**正式签名**包：导航独立栈、设置二级页、标签分组、搜索建议、更新续传、提醒下线、站点 logo 图标 |

- 下载托管：`http://154.8.194.198/downloads`（**宿主机 nginx**，不是 compose 里的 `otaku-nginx`；
  `docker ps` 只有 backend / mysql）。站点配置 `/etc/nginx/sites-enabled/otaku-downloads`，
  `alias /opt/otaku/downloads/`。2026-11-01 实测：清单 200、`latest.json` 带 `no-store`。
  目录只剩 `otaku-1.1.3.apk` + `otaku-1.1.4.apk`（各 20MB），旧的 debug 包已清。
- ⚠️ **后端 `:8080` 不服务 `/downloads`**（实测 404）。客户端默认按 `<API_BASE_URL>/downloads` 拼，
  所以出包必须显式带 `--update-base-url http://154.8.194.198/downloads`；
  #319 合入后改为优先读 `site.conf` 的 `UPDATE_BASE_URL`（`chore/update-url-in-site-conf`），
  漏传一次就会出一个「更新地址是旧 IP」的包，要到用户点更新才发现。
- 正式签名指纹（**以后每个包都必须一致**）：
  `SHA-1 ebeb5f19f2734592e20f7f5868418d90afbada74`
  / `SHA-256 dce1164a26eafd7396b8842be06817c11a70ff82dc23a63575c7a4bd50d8647a`
- ⚠️ **地址是裸 IP + 明文 HTTP**，域名定了要重出包；已装内部测试版的人届时需卸载重装。
  因此这段时间**只给内部两三个人装，不要扩散**。

### 验收项进度（[`acceptance.md`](acceptance.md) §4.1）

| 项 | 状态 |
|---|---|
| E9 Release 包签名 | ✅ 正式 keystore，`apksigner verify --print-certs` 通过 |
| E10 图标与包标识 | ✅ 站点 logo（自适应图标 + 五档位图）；`com.otaku.app` / `Otaku` |
| E11 下载入口可用 | ✅ 清单 200、APK 支持 HTTP 206（断点续传可用）；**注意只在 `:80`，`:8080` 是 404** |
| E12 应用内更新闭环 | ✅ 真机实测：1.1.3 → 检测到 1.1.4 → 下载 → 安装 |
| E13 域名与 HTTPS | ❌ **等域名**，唯一阻塞 |
| E14 干净设备能装能起 | ✅ 卸载 debug 签旧包后一次装成 |

## 1. 栈关系（历史，已全部落库，现无在飞栈）

```
article-sync (#110)        ⊃ schedule-sync (#105)
collection-offline (#116)  ⊃ tag-filter (#107) ⊃ offline-cache (#103)
client-home (#121)         ⊃ 上述全部（原基于演练分支 ci/merge-train-2026-10-23）
search-and-settings (#123) ⊃ client-home (#121)
reminders (#128)           ⊃ search-and-settings (#123)
filter-links (#130)        ⊃ client-home (#121)
```

三种「叠」的后果不同，别再踩：

- **合栈顶、关底座** → 零冲突（当时的选择）；
- **先合底座、再合栈顶** → 重复应用，实测 `#105 → #110` 产生 **18 处冲突、7 个文件**；
- **合了底座却不合栈顶** → 功能进去了，但 PR 里那个栈顶会一直显示「冲突」。

## 1.5 合并方式会改变顺序策略

`main` 上两种合并方式并存：

- **squash**：单亲提交、标题带 `(#NNN)`，占多数；
- **merge commit**：`Merge pull request #NNN from …`，功能整合批（#134/#136/#137）用它保留被整合分支的历史。

| 合并方式 | 先合底座（#105 → #110） | 说明 |
|---|---|---|
| **squash** | 冲突（实测 18 处 / 7 文件） | squash 产生**新提交**，底座的提交不进 main 祖先链，上层 diff 仍含底座改动 → 重复应用 |
| **merge commit** | 安全 | 底座成为 main 祖先，`merge-base` 自动前移，上层只剩自己的改动 |

> ⚠️ 由此带来一个判断陷阱：**squash 合过的分支，`git merge-base --is-ancestor` 会说「没进 main」**，
> 但内容其实在。判断「进没进」只能看代码/提交，不能只看祖先关系或 PR 的 merged 标记
> （zm 会直接关掉栈上 PR 而不是合并，#121/#123/#128 都这样）。

## 2. 合并进度

| 批 | 整合 PR / 提交 | 含原 PR | 结果 |
|---|---|---|---|
| 第 48 批 · 系列名双编码修复（11-10，1 提交） | #584（#559 衍生） | pyxz0 | 做系列页预览时发现生产 `series.name` **910 / 941** 条是双编码：`机动战士高达` 存成了 `æœºåŠ¨æˆ˜å£«é«˜è¾¾`（`E6`→`C3A6`、`9C`→`C593`），而 `GET /api/series/{key}` 是原样透传，系列页标题会直接乱码。**先修数据**：`mysqldump` 备份 + 备份表 `series_name_backup_20261110`，单事务按 `series_key` + 旧值双条件更新 **910 条**（31 条纯 ASCII 不动），校验「总数 941 不变 / 二进制比较残留 0 / 线上 154 → 机动战士高达」，回滚只需一条 JOIN UPDATE。**再兜根因**：`cleaning.repair_mojibake` 按 MySQL latin1 语义（= cp1252 超集）还原字节再按 UTF-8 解，只在「字节合法 + 结果不同 + 不含 `?`」时认，正常 CJK / `café` / ASCII 都不动；`_series_names_for` 发送前调用并计数，`PublishReport.series_names_repaired` 进报告 + 一条 warning。**关键坑**：MySQL 的 latin1 不是 ISO-8859-1，真实名字里 `œ/Š/–`（cp1252 独有）与 `0x8F/0x90`（cp1252 未定义、按同码位控制字符存）混在一起，纯 cp1252 或纯 latin-1 编码都会抛异常，必须逐字符降级；另外 `name LIKE '%Ã%'` 在 `utf8mb4_0900_ai_ci` 下等于 `LIKE '%a%'`（重音不敏感），数残留必须 `COLLATE utf8mb4_bin` 或直接看 HEX。`sync-python` **319 passed**；**根因仍在产出数据集的上游**，重发数据集前这套兜底会一直生效。 |
| 第 47 批 · 首站原生级体验 v1 · 后端 P1 三件（11-09，3 提交） | #570（#561 首页海报）/ #571（#557 公司页 + 系列页 + 关系标签）/ #572（#560 搜索） | pyxz0 | **#561** `GET /api/home/posters` 现算 12 条，不建名单表/不轮转/不定时。三个坑写进实现里：① 类型判据必须落在 `work.work_type`——`schedule.work_type` 存的是「TV动画」这类来源原词，生产 202610 季按 `anime` 比 **0/69** 命中，照字面写 hero 永远空；② 封面判据是**磁盘缓存可读**（`CoverService.isCached`）而不是 `cover_source_url` 非空，URL 有值但回源 404 的情况真实存在（生产 66 部当季动画只有 17 部有缓存）；③ 顺序 `rating_sort → weekday（NULL 沉底）→ title → id`，刷新一次换一个排列在端上就是 bug。**#557** 新增 `GET /api/studios/{name}` 与 `GET /api/series/{key}`，给详情页「系列作品」补 `relation`：公司名 NFKC+strip 后 **`COLLATE utf8mb4_bin`** 精确匹配——默认 `ai_ci` 会把 `A-1 Pictures` 与 `a-1 pictures` 并成一家；排序统一走 `rating_sort`（契约原文写 `rating_value`，会让「5 人打 10 分」顶到第一，是 #383 修过的问题）；系列页 404 **只在「系列行与可见作品都没有」时给**——有作品没系列行是常态（两张表分开导入）。系列区 `items` 从裸卡片改成 `{relation, work}`，**关系数据还没落库**（数据集 `work_relations` 只有建表、publisher 不写），所以现在只会给 `same_series`；该接口此前无客户端调用，形状变更无兼容负担。**#560** 搜索多路召回 + 三档：四路各扫一遍再 `UNION`（生产只读压测，零命中 1.57s → 0.45s），`SUM(is_adult = 0/1)` 一次扫描同时出可见数与成人遮挡数；`SearchQuery` 纯函数解析年份/类型/季数（整 token——`游戏王` 不会被拆成「游戏 + 王」；季数只认 ≥2；剥完主体为空就放弃拆分）。**一次请求约 1.6s 上界**（最坏输入），已写进契约与交接文档，客户端建议 ≥400ms 防抖。同批给红线 **#564（信息卡 4 列）** 与 **#567（投稿四条写路径）** 出了后端确认帖：前者把 `official_url` 提到 1024、给了 `infos` 数组形状；后者纠正了「work_id 由 sync-python 生成」的误解（实际是 Java `PublicIdGenerator`），并指出 `site_listed=0` 会让作者看不到自己通过审核的作品。后端 **637 通过 / 0 skipped**；契约 **83 / 142 / 122**，`check-contract.py` 通过。**无迁移**；**未发版**——待 #564 / #567 与客户端 P2 一起联调。 |
| 第 1 批 · 后端与同步 | #134（`ad07012`） | #102 / #109 / #110（含 #105） | backend 111 / pytest 110 |
| 第 2 批 · 客户端主链 | #136（`a1f4d1c`） | #116（含 #107 / #103）/ #106 / #112 / #114 | flutter 193 |
| 第 3 批 · 客户端栈顶 | #137（`ac51dbd`） | #121（含 #122）/ #123 / #128 / #130 | flutter 252 |
| 第 4 批 · 文档与呈现适配 | #143 / #111 / #120 / #145 | 列表 `source` / W1 看板 / D3 决策 / 能力清单 | backend 111 / flutter 258 |
| 第 5 批 · 拍板落账与验收 | #141 / #142 / #148 / #168 / #169 / #171 | 授权形态、C1/D1 记账、档期页侧栏、渲染边界 | flutter **305** |
| 之后（他人主导） | #127 / #147 / #151 / #162 / #163 / #174–#189 | 资讯契约、账号绑定草案、状态追认、契约守卫、封面防盗链等 | 各 PR 自身 CI 绿；本轮未重跑全量 |
| 第 6 批 · 后端能力补齐 | #193 / #190 / #208+#212 / #144 二期 / #216 / #217 / #218 / #209 / #213 | 年份筛选、设备令牌、标签词表、站主后台与审计、限流与 CORS、真机部署、VNDB 适配器 | 均已在 `:8080` 上线；后端 209 通过（#216 记录）、pytest 174（#213 记录） |
| 第 7 批 · 客户端改版 + 契约扩容（10-28，49 提交） | #228–#234 / #263 / #243 / #241 / #250 / #255 / #237 / #248 / #252 / #264 | 首页/卡片/移动端布局改版、底部导航、站内 WebView 授权、富字段与关系四表、数据集提交与变更感知、VNDB 适配器拆分、`otaku-bangumi` 重键 | 客户端功能面清空；契约档 A/档 B 与实现同步落库；VNDB 不再继承首站适配器 |
| 第 8 批 · UGC 与数据收口（10-29，24 提交） | #275(#270) / #276+#277(#273) / #279(#278) / #280(#249) / #281–#284(#240 B1/B2a/B2b/B2c①) / #285(#271) / #287(#286) / #291(#240 B2c②) / #293(#240 B2c③) / #294(#240 B2c④) | 标签索引、别名脏值清洗、锁冲突重试、作品软删、评论/开关/举报/导出/回复、留存清理与下线清单、编辑、people 补人、指标端点 | 全部已发版；后端 **301** 通过（#294 记录）、pytest 274（#276 记录） |

每批整合 PR 合入后，**源 PR 已逐条关闭**并留了「已随 #NNN 合入」的说明。
第 8 批为单 PR 直合（无整合 PR），编号形如 `#275(#270)` = PR #275 关闭 Issue #270。

（10-30 起续一张表，编号接着上面）
| 批 | 整合 PR / 提交 | 含原 PR | 结果 |
|---|---|---|---|
| 第 9 批 · 客户端整合（10-30，4 提交） | #302（`af78b85`，含 cherry-pick 的 #299 `09a23e9` + `085d1e3`） | 导航独立栈、设置二级页、标签面板分组、搜索建议面板、更新包断点续传、外观实验（系统取色 / 玻璃质感，默认关）、追番提醒下线、封面与标签行 | 客户端 **391 通过 / 0 失败**（见 §5）；后端未动 |
| 第 10 批 · 注销与发版规程（10-30，3 提交） | #300（发版冒烟规程，`e010087`）/ #305（#240 B2c⑤ 注销，`988c618`）/ #306（鉴权路径修复，`c9f569d`） | `DELETE /api/me` + 匿名化保留、保留期改 15 天、下线确认函模板、发版后 7 项冒烟 | 全部已发版；CI 全绿；生产逐项冒烟 |
| 第 11 批 · 点评（10-30，1 提交） | #308（#240 B2c⑥，squash 后 `b536801`） | `ugc_review` 一人一条、打分 + 长评、均分只算打了分的、与评论不打通 | 已发版；CI 全绿；生产冒烟 |
| 第 12 批 · 旁路两件（10-30，2 提交） | #301（覆盖率报告工具，zhengmin486）/ #303（nginx 静态托管安装包，riceyu02） | 数据集覆盖率工具（sync 侧，纯新增）；`/downloads` 静态托管 + compose 挂载 | CI 全绿；compose 里的 `otaku-nginx` **没有启用**，`:80` 实际由宿主机 nginx 服务（见 §0.5），所以「不影响生产」成立，但两套配置并存 |
| 第 18 批 · 看板追平与 UGC 收口（10-31，9 提交） | #335 / #336 / #337 / #338 / #339 / #340 / #341，并入 #314（交付物探针）/ #319（`UPDATE_BASE_URL` 读 site.conf） | 码点计长 + 评论 429 带 `Retry-After`；站点下线脚本补删点评；导入来源必须登记到站点（未登记 400）；契约联调真实 ticket；控制台导出按 `type` 分三类；交付物探针与 E9–E14 验收；换域名只改 `site.conf` | 后端 **380 通过**（#341 记录，含连库集成）；CI 全绿；生产逐项冒烟 |
| 第 13 批 · Android 发版能力（10-30，2 提交） | #317（release 签名读 `android/key.properties`）/ #318（启动图标换成站点 logo，含自适应图标） | riceyu02 | CI 全绿；缺密钥时签名构建会明确告警而不是静默出无签名包 |
| 第 14 批 · 成人内容不可见（10-30，3 个迁移） | #321（V25 `is_adult`）/ #322（V26 标题兜底）/ #324（V27 运行期配置） | riceyu02（后端） | 已发版；判定落在数据库列而不是查询时现算（现算把列表计数从 86ms 拖到 2.7s）；词表与开关改完即生效 |
| 第 15 批 · 使用统计开了又撤（10-30，2 提交） | #326（访问日志 + 心跳）/ #328（revert） | riceyu02 | 当天上线又撤回；结论是**暂不做使用统计**，别再从日志里想办法 |
| 第 16 批 · UGC 机器审核接入位（10-31，2 提交） | #329（#240 B2c 最后一项）/ #330（生产 compose 透出 7 个 UGC 变量） | pyxz0 | 默认 `provider=none`；生产实测 8 条（pass/review/reject/编辑重审/只打分不送审）；`provider` 配错启动即失败 |
| 第 17 批 · 运维与交付文档（10-31，4 提交） | #331（备份恢复演练）/ #332（巡检告警通道 + 两个脚本 CRLF 修复）/ #333（看板待外部输入）/ #334（UGC 真实响应样张） | pyxz0 | 真实 dump 恢复演练 24 表一致；巡检失败现在能发 webhook（当天**生产未配地址**，11-01 已补上，见 §6） |
| 第 19 批 · 首站收录范围（11-02，1 提交） | #379（#370 后端，squash 后 `83e038b`） | pyxz0 | V28：`site_scope` 转正式表 + `work`/`work_tag` 的 `site_listed`；清掉 11-01 应急用的 `2099-01-01` 哨兵；回填 18,828。迁移在真实副本上先验（13.2 s），生产停机 **19 s**；可见 **25,729 → 18,676**，未收录的详情/评论 404，词表与推荐同步收口。386 通过 / 0 skipped |
| 第 20 批 · 档期修复与手机端（11-02，3 提交） | #387（档期默认季度）/ #388（手机端两轮体验 + 个人空间页）/ #389（SDK 迁移记录） | riceyu02 | `#387`：默认季度不再取到伪季度（`unreleased` → `202610`，首页「本日新番」由**整块空**恢复为 69 条 / 7 个 weekday 组），例行重导不再把 `work_id` 冲成 null；`#388`/`#389` 纯客户端与开发文档。**#387 由 pyxz0 发版**：无迁移、启动 6.9 s、冒烟 7/7、`/api/works` 仍 18,676 |
| 第 21 批 · 低票评分口径（11-03，2 提交） | #393（#383 后端，squash 后 `ee678d5`） | pyxz0 | `V30`：`rating_sort` VIRTUAL 生成列 + `(rating_sort, id)` 索引，排序仍在索引上有序扫描（不能直接 `ORDER BY CASE`——实测会退化成全表扫 163,229 行 + filesort）；展示层按 `rating_count < 50` 把 `main_rating` 置空，票数未知不隐藏。副本先验（V30 911 ms）→ 生产 V29+V30 **2.06 s**、停机约 12 s、冒烟 7/7；上线后已收录作品 **2,676 展示 / 558 隐藏 / 14,622 票数未知** |
| 第 46 批 · 画像九维 + 冷启动补标 + 抛弃态热修（11-09，4 提交） | #555（抛弃态）/ #563（#498 + #505）/ #565（文档）/ #566（搜索补标） | riceyu02 | **#555 是线上故障修复**：我部署 `897b45d`（功能开关）时把 #540 一起带上生产——收藏状态从三态变四态（`dropped`），而客户端 `CollectionStatus.parse` **遇未知值直接抛**，账号里只要有一条「抛弃」就**整页收藏解析失败**（详情页收藏态、个人空间统计同链）。修法：加 `dropped('dropped','抛弃')`，`profile_stats` 的 switch 补分支（抛弃计入收藏总数、不算看过/想看）；新增 `collection_status_test.dart` 9 项，钉「契约每个取值都必须能解析」。**规律：后端 `enum:` 加值对老客户端是破坏性变更**（客户端目前只有这一处严格 parse，`WorkType.value` 是回落 `unknown`）。**#563**：`PersonaInsightMapper` 整段重写，删掉端上六轴（类型集中度/题材广度/口味浓度/评分态度/活跃度/近期活跃），改为直接消费 `dimensions` 九键（键序 `tag_focus…completion`、0–100、缺维给中性 50、clamp）；接 `hero_title`/`hero_code`/`hero_note`/`final_quip`/`persona_tags`/`trait_blurbs`/`rarity`；页面重排为称号卡（含 #490 稀有度徽章配色）→ 九维雷达 → 标签逐条解读 → 锐评 + 收尾。**#505 补标页** `/me/persona/quiz`：`GET /api/persona/quiz?seed=&size=`，点「看过/在看/抛弃」写 `PUT /api/me/collections`（`source=quiz`，无新表），20/100 切换、换一批 `seed+1`、进度**按服务端 `size`**、写失败不前进、未登录直接说明。**#565**：`persona-mapping-proposal.md` 顶部标注「已被 #498 取代」（正文留作决策历史，避免有人照它把公式加回来）。**#566**：搜索补标 `/me/persona/quiz/search`，复用 `GET /api/works?q=`、去抖 350ms、请求序号丢弃过期响应、标完就地回显「已记 · 看过」；**不做分页**（补标是「找到那一部就走」）。flutter **604 通过 / 0 失败**、analyze 干净。**未发版**——1.1.8 待发内容 = #552 + #555 + #563 + #566；其中 #555 是修线上故障，优先。 |
| 第 44 批 · 客户端接四个新接口（11-07–09，6 提交） | #518（头像 + 账号资料）/ #519（资讯收藏）/ #522（画像提示文案）/ #532（作品点评）/ #533（#375 映射定稿）/ #549（点评换新端点） | riceyu02 | 后端 b34/b35 与 #516 / #531 已上线，客户端跟随。**#519 资讯收藏**（消费第 32 批的后端）：数据源从「全量只读」补成 `fetchPage` + 单条状态 + `PUT`/`DELETE`；控制器 state 换 `ArticleFavoriteData`（**分页错误与首屏错误分开**，翻页失败不清空已看内容）；列表滚动加载（提前 400px 触发）+ 取消收藏（**乐观移除、失败插回原位**）；资讯详情页 AppBar 收藏按钮；个人空间入口直开**资讯分段**。**#518**：`GET/PUT /api/me/account` + `multipart` 头像（字段名 `file`，≤2MB、魔数校验、1 分钟 1 次），429 走 `userMessage` 带秒数；头像与资料**分成两个数据源**（失败语义不同）。**#532 + #549 作品点评**：详情页「我的点评」（概览 + 打分 + 编辑/删除）。#532 时契约还没有「查我的点评」，只能拉公开列表比对 `author`；#541 上线后 #549 换成 `GET /api/me/reviews?work_id=`，**不再需要用户名**，并按 `status` 区分「审核中 / 被隐藏 / 已删除」（后两者不展示内容、不给编辑——编辑一条被隐藏的点评不会让它重新公开）。**#533**：`persona-mapping-proposal.md` §7 三点按推荐值定稿（六轴采用方案 A / 热度砍掉 / 补字段暂不提）。⚠️ 三个踩坑：320 宽 2 倍字号横向溢出 53px（`Row`→`Wrap`）；**mock 的 `Future.delayed(Duration.zero)` 仍会留 Timer**（`!timersPending`，widget 测试会红）；**`PATCH /api/me/reviews` 是「省略 = 沿用」而 `PUT /api/me/account` 是「null = 清空」，两个端点语义相反**。flutter **588 通过 / 0 失败**、analyze 干净。**已发版 1.1.7（versionCode 8）**：2026-11-09 02:15 发布，arm64 / 正式签名 / `USE_MOCK=false`，包 21.7 MB、sha256 `5043bded…`；`latest.json` 已切、下载 200 实测，保留 1.1.6 供回滚。 |
| 第 45 批 · 题面端点与文档纠偏（11-09，2 提交） | #547（#403 文档）/ #548（#492 题面端点） | zm | **#547 纯文档**：`relation-algorithm-decisions.md` 改两处口径——源库 `tags` 只有 `(id,name)`，dataset 的 `kind` 是从未写入的占位，所以「数据侧补 `tag_kind`」这个任务立不出来；等权是终值不是过渡，路径①没有到期日。不改 pyxz0 原话，只在段后补事实。**#548 新增对外端点** `GET /api/persona/quiz?seed=&size=`：`QuizSampler` 移植 `scripts/sample_quiz_works.py` 的分层策略（题材 8 桶各 40%、年份 20/35/45、跨热度等间隔、同系列只一部），`QuizService` 查候选 → 抽样 → 复用 `WorkSummary` 卡片；**匿名可读**，写答案仍走 `PUT /api/me/collections`（`source=quiz`）。**刻意不对齐网站 seed**：Python 的 `random.Random(str(seed))` 是 MT19937+sha512 播种，Java 里逐位复现会随 CPython 内部实现变；保证的是「同 seed 在本服务稳定」。`size` 1–200 之外 400 不静默夹取；SQL 排序补 `work_id` 兜底键，否则同分作品换序会让同 seed 出不同题面。**跨模块契约变更**（新增 path + `QuizPaper` schema）已按红线流程在 PR 与 #492 / #505 通知消费方。Java **390 通过**（175 skipped=真库 IT）、契约与站点隔离通过。**无迁移**；**待发版**。 |
| 第 43 批 · 画像称号体系与三份决策（11-08，5 提交） | #527（#500）/ #545（#494 接线）/ #530（#403）/ #521（#504）/ #520（#503） | zm + pyxz0 | **#527**：把网站 `persona.py`（`COPY_VERSION=4`）整层文案与判定搬过来——`PersonaCopyData`（95 条称号文案）、`PersonaTitle`（六层判定）、`PersonaShareCodec`（分享参数编解码），附 15 条 parity/校准用例。**#545**：`#529` 的 rebase 版（原 PR 基线是 #527 分支，retarget 后与 #536/#540 冲突）。补上 `hero_*` / `persona_tags` / `trait_blurbs` / `final_quip` / `rarity`；**只改一处语义**——原作者留的 `drop=0` 常量接到 `droppedWorks.size()`（#540 之后才有数据），「三集弃之神」从此刻起能真正命中；称号的题材/身份占比剔除被抛弃的作品。**#530**：关联算法七项确认收尾（第 2 项按 A 案）。**#521**：分层抽样口径移植为可单测纯函数 + 题面清单脚本（sync-python）。**#520**：UGC 对外策略文档（三项硬前置 / 四档灰度 / 回退口径）。后端 **584 通过 / 0 skipped**；契约 **79 / 137 / 117**（`PersonaRarity` 新增）；`sync-python` / `scripts` 通过。**无迁移**；**未发版**。 |
| 第 42 批 · 漏斗种子来源（11-08，1 提交） | #543（#506） | pyxz0 | **V38** 加 `collection.source`（`user` / `quiz`，默认 `user`，存量与老客户端语义不变）。**规则写在 SQL 的 WHERE 里**：`NOT (source='user' AND :source='quiz')`——不先查后判，否则并发下「先查都看到 seed」会让规则漏掉。**种子盖不动用户操作**，被挡下**不报错**、返回当前状态（批量写不该为一条种子变成半成功）；**反向永远允许**：用户写一次即转成 `user`，之后漏斗再也盖不动。PUT / PATCH 都走同一条 `applyWrite`（原计划 PATCH 强制 user，会让种子伪装成用户操作、反被自己的规则挡住）。`source` 非法 400，不静默降级。客户端只需在漏斗 UI 带 `source=quiz` 调现有收藏接口，**无新端点、无新表**。后端 **565 通过 / 0 skipped**（+4 真库 IT）；契约 **79 / 136 / 116**。**未发版**（instant DDL）。 |
| 第 41 批 · 抛弃态与查我的点评（11-08，2 提交） | #540（#496）/ #541（#531） | pyxz0 | **①「抛弃」= 收藏第 4 态**（`dropped`）：`status` 是 `VARCHAR(16)` 且无 CHECK，**无需迁移**；画像里记 **-2.0**（与点评 1–4 分同量级，当成 `want` 会让符号反掉），且**被抛弃的作品不进九维分母**（完成度 4 部里 1 看过 1 在看 2 抛弃 = 50% 而非 25%；浏览过又被抛弃的也剔除——浏览不能把拒绝洗白）；站主后台过滤与聚合加 `dropped`，与 `none` 分开（否则「被否掉」会被算成「没分类」）。**依据**：#492 11-07 已拍板「标注词表对齐收藏三态 + 抛弃负向进避雷」，只是没回填到 #496。**② `GET /api/me/reviews?work_id=`**：客户端拿回自己的 `review_id`（原来只能拉公开列表按作者名比对，点评超过一页时自己的那条不在第一页 → 误判没写过 → 撞 409 且永远改不了）；返回分页信封（0/1 条），没点评过是空 `items` 不是 404，`status` 原样返回含 `deleted`。**已知限制**：软删后不能重新发表（唯一键 + `exists` 不过滤 deleted），修法要先定「复活 vs 硬删」，已写进 `client-dev-handoff` §14。**无迁移**；后端 **561 通过 / 0 skipped**（+12）；契约 **79 / 136 / 116**。**未发版**。 |
| 第 40 批 · 九维口径修复（11-08，1 提交） | #536（#497 修复 1/2） | pyxz0 | **① `exploration`**：`distinctGenres == 1` → **10**，`== 0`（没有题材数据）仍 50——原来两者共用中性分支，导致「只吃机战」拿 50、比「24 题材各看一点」（57）还像博爱。**② `emotion`**：删掉 `EMOTION_MIN_SAMPLE = 8` 的硬门槛（治愈+致郁只占 8.25%，12 部命中 ≥8 的概率约**万分之四**），改成 4 部伪计数收缩 + 输出「**相对全站配比的偏离**」（`oriented = (治愈-致郁+4×0.528)/(并集+4)`，与全站同配比 = 50）；分母不退回「全部有标签作品」，否则「收藏多但没几部情绪番」会被压成「偏暗」。**③ 顺带纠正一处统计口径**：基础率 **22.3% 是错的**——那是 `work_tag` 的**标签行数** 4,200 / 18,828 部作品，一部作品常同挂「治愈」「温馨」「萌」；按作品去重是 **1,445 / 17,524 = 8.25%**、治愈:致郁 **76:24**（非 85:15）。这个错把密度高估近三倍，正好掩盖「轻度用户恒 50」。**效果**（60 部/人）：治愈 97→**92**、致郁 9→**5**、平均 **76→47**；12 部：治愈 97→**84**、平均 50→**56**。**回归断言**：反镜子（平均须落 50±10）、小样本（12 部治愈 > 博爱 +15）、两端（致郁 < 平均 −15）、边界（单题材 10 / 无题材 50）。**口径版本 4 → 5**（本地两处修正，网站仍 4，别直接比数值）；**无迁移、不动 DTO**；后端 **549 通过 / 0 skipped**；契约 **79 / 136 / 116**。**未发版**。 |
| 第 39 批 · 九维区分度诊断（11-08，1 提交） | #534（#497，父 #490） | pyxz0 | **诊断结论：不是维度设计差（A），是口径（B）**。生产只有 4 账号 / 0 收藏，没有真实样本，改成构念效度测法：11 类**口味已知**人群 × 10 人 × 12/60 部两种规模，看九维能不能分开。样本按生产分布校准（年份 decade 计数、热度 P10/P50/P90=23/147/2266、治愈+致郁 22.3%——**该值已纠正为 8.25%，见第 40 批**）。**结果**：`mainstream` 92 vs 21、`fresh` 100 vs 0、`tag_focus` 100 vs 38、`exploration` 7 vs 57、`quality` 92 vs 50 都分得开；`pop_spread` 11 类里 9 类 98–100、`era_span` 8/11=100（**天花板**：REF 12 年 / 25 个百分点太低）；`emotion` 轻度用户恒 50（命中 ≥8 的概率 0.04%）、60 部时变「全站基础率的镜子」。顺带验证 `POP_ANCHORS`：生产 P50=147 vs 锚点 129，反推百分位最大偏差 +5 → **不用重标**。**无生产代码改动**；新增 `PersonaDimensionDiagnosticsTest`（方向断言 7 条 + 现状钉住 2 条 + 塌缩底线 std>5）与 `docs/persona-dimension-diagnostics.md`。后端 **548 通过 / 0 skipped**。**未发版**。 |
| 第 38 批 · 九维接进画像（11-08，2 提交） | #525（算法纯函数，zm）/ #526（接线，pyxz0） | zm + pyxz0 | `PersonaDimensions`（纯函数，口径对齐 `persona.py` DIMENSION_VERSION=4）+ `PersonaProfile.dimensions`。**接线三原则**：按**作品**去重（同一作品在浏览/收藏/点评三路各一行，不去重会让 `completion` 失真——3 部作品 1 部看过，去重 33.3% / 不去重 25%）；`status` 只从收藏行取（浏览/点评行是 null，不能覆盖已有 `watched`）；评分沿用 #495 口径。**缺失给 50 不给 0**（0 在雷达图上是凹角，会被读成「这方面很弱」）。⚠️ `tag_focus` / `exploration` 目前恒 50：要「哪些标签算题材」的白名单，仓库无权威来源（`work.tags` 混了题材/公司/角色，数据集 `tags.kind` 没导入），做成 `app.persona.genre-tags` 配置默认空，不硬编码名单（#467 已否过一次）。`hero_*` / `final_quip` / `persona_tags` / `rarity` 未做，等 #497 诊断结论。**无迁移**；后端 **546 通过 / 0 skipped**（3 条服务测试 + 2 条真库 IT）；契约 **79 / 136 / 116**。**未发版**。 |
| 第 37 批 · 系列关联（11-08，1 提交） | #523（#411，父 epic #403） | pyxz0 | `V37__work_series.sql`：`work.series_key` + `idx_work_series (series_key, release_year)` + `series(series_key, name)` 独立表。**为什么 key 放 work 不建关系表**：一部作品只属于一个系列，一对多不需要中间表，关系表只会让唯一访问方式多一次 join。导入：`ImportItem` / `NormalizedItem` 加 `series_key` / `series_name`，**只有数据集通道给**；省略或 null = **不覆盖**已有归属（与富字段同一条铁律），先 upsert 系列行再写作品、同一事务，名字为空保留旧值，只改归属也计 `updated`。接口：`GET /api/works/{work_id}/series` → `{series_key, series_name, items}`；无系列返回 200 + null + `[]`（不是 404），`items` **含当前作品**、按**年代升序**且年份未知沉底（MySQL 的 `ASC` 会把 NULL 排最前，不显式写 `release_year IS NULL` 会让「年份未知」冒充最早），排除已下架/未收录/成人。数据侧 `publisher` 同步带上两字段（`_series_names_for` 按批取名）。**无破坏性契约变更**；后端 **531 通过 / 0 skipped**（7 条真库 IT）、`sync-python` **304 passed**；契约 **79 / 136 / 116**。**未发版**；V37 随下次发版执行，数据要等数据集重跑一次。 |
| 第 36 批 · 源站评分进画像（11-07，1 提交） | #516（#495，父任务 #490） | pyxz0 | `findSignals` 三路（view / collection / review）都带 `w.rating_value` / `w.rating_scale`，评分倾向改为「**自己的点评分优先，没有才回落来源站均分**」并**按 `work_id` 去重**——三路 `UNION ALL` 会让同一作品出现多次，不去重等于把分数算三遍；去重还必须与顺序无关，否则时间更新的浏览行会带着站内均分抢在用户自己的点评分前面（用 `ownRatedWorks` 挡住回落值，有用例）。`rating_scale` 只认 `0-10` / `1-10` / 空（空按 0-10，生产 94,443 行全是 0-10），`0-5` / `percentage` 等**不猜**（返回缺失）——猜错会把 5 分制的 4 分当 10 分制的 4 分。`rating_tendency.count` 语义从「打过分的点评条数」改为「有评分的作品数」，契约描述已同步。**无迁移**；后端 **524 通过 / 0 skipped**（4 条单测 + 2 条真库 IT）；契约 **78 / 135 / 115**。**未发版**；九维 `dimensions` 仍在 #494（缺 persona.py 基准源码，已在 issue 说明）。 |
| 第 35 批 · 站点解绑与身份来源（11-07，1 提交） | #514（#147 / W1 后端三项输入） | pyxz0 | `POST /api/auth/site-unlink`：清 `identity_source` / `site_token_hash` / `site_token_expires_at`、**保留账号与全部数据**、撤销该账号**全部会话**；平台账号 `409 NOT_SITE_LINKED`；**保留 `external_user_id` 作为重连锚点**——同一站点身份再次授权按它接回原账号（`user_id` 不变，数据不丢），已注销（`status=disabled`）的账号不会被复活。`User.identity_source`（`null` / `otaku_site`）在 `/me`、`/login`、`/site-login` 三处同口径，`site-login` 的 DTO 不再手写站名字面量。路径挂 `/api/auth/**`（身份动作），`AuthFilter` 白名单加**精确路径**并补正反两条断言——2026-10-30 `/api/me` 漏了这类路径的表现是 400 不是 401。**没做 self-revoke**：平台只存令牌 SHA-256（契约 §7），站点 `POST /api/auth/revoke` 要原始 Bearer，调不动；要即时吊销需站点按映射吊销或平台可逆存储，两者都要三人确认，客户端文案不得写「已立即吊销」。寿命关系已定：平台会话 30 天与站点令牌解耦，客户端只做 401 被动重走。**无迁移**；后端 **518 通过 / 0 skipped**（新增 6 条真库 IT + 2 条路径断言）；契约 **78 / 135 / 115**。**未发版**。 |
| 第 34 批 · b35 人物页热修（11-07，2 提交） | #511（compose 调度池默认 3→4）/ #512（V36 people 前缀 + 反查索引 + 新旧键兼容） | pyxz0 | **#511**：生产 `.env` 没有 `OTAKU_SCHEDULER_POOL_SIZE`，而 compose 显式默认 3 会覆盖应用默认 4（#469 的回归），发版前改成 4 并注明两边必须同步。**#512**：b34 上线后实测 `/api/persons/bgm:3818` **404**——V33 只把 `work_staff` / `work_characters.person_id` 改成 `bgm:`，`people.source_id` 仍是 v2 裸数字，75,745 条配音关系 100% 匹配不上；V36 把 19,399 行 people 纯数字键补成 `bgm:`，并补 `idx_work_staff_person` / `idx_work_characters_person`（V33 落地后迁移号不再被挡）。`PersonService` 把纯数字入口归一化为 `bgm:<id>`、`bgm:` 查不到 people 时回退裸键（灰度/回滚安全网），返回统一 `bgm:` 形式。新增「v2 裸 people + v3 关系」用例；**511 通过 / 0 skipped**；热身后 `persons/bgm:3818` **46–66 ms**（原 140–170 ms，再早 460–570 ms）。**已发版**（2026-11-07 20:30，`b34` → `b35`）。 |
| 第 33 批 · 账号资料与头像（11-07，1 提交） | #509（#378 后端） | pyxz0 | `V35__account_profile.sql`：`app_user` 加 `display_name` / `bio` / `avatar_key`。`GET/PUT /api/me/account`（昵称 ≤32、简介 ≤200，空串归一 null，超限 400）；`POST/DELETE /api/me/account/avatar`（multipart ≤2MB，只认魔数，重编码 512×512，1 分钟 1 次）；`GET /avatars/{public_user_id}-{内容指纹}.{webp\|jpg}` 公开读 + 7 天强缓存。**两处对方案的修正**：① 资料是独立 `AccountProfile`，没往 `User` 塞字段（`User.display_name` 是站点昵称、仅当次展示，与平台自设昵称语义不同）；② 路径用 `/api/me/account` 而不是 `/api/me/profile`——后者已被阿宅画像（#471）占用，同路径 GET 画像、PUT 资料不可解释。头像优先 WebP（`webp-imageio`），不可用退回 JPEG；文件名带内容指纹，换头像即换 URL。踩坑：WebP writer 只设 `MODE_EXPLICIT + quality` 会抛 `No compression type set!` 并静默退回 JPEG，必须补 `setCompressionType`，已加「有 WebP 编码器时必须真产出 WebP」用例钉住。注销 `AccountDeletionProfileListener` 先清 key 再删文件。compose 加 `avatar-data` 卷，`backup.sh` 每日把 avatars 打成独立 tar.gz（失败只告警）。契约 +3 schema，`check-contract` **77 / 135 / 115**；后端 **510 通过 / 0 skipped**（4 条图片单测 + 6 条真库 IT），真 jar 端到端验证 `.webp` / `image/webp` / 缓存头。**已发版**（2026-11-07 20:30，`b34`）。 |
| 第 32 批 · 资讯收藏后端（11-07，1 提交） | #507（#377 后端） | pyxz0 | `V34__article_favorite.sql`：独立表 + `(user_id, article_id)` 唯一键 + `(user_id, updated_at)` 索引。四个端点 `GET /api/me/article-favorites`、`GET/PUT/DELETE /api/me/article-favorites/{article_id}`；`PUT` 用唯一键 + `ON DUPLICATE KEY UPDATE` 做幂等 upsert，`DELETE` 不存在也 204，未收藏是 `200 + favorited:false`，只有资讯不存在才 `404 ARTICLE_NOT_FOUND`。列表 `updated_at DESC, article_id ASC`，内嵌 `ArticleSummary`（**不含正文**），**计数与列表同一 JOIN `article` 口径**——资讯已不在表里时收藏行不占位，否则会出现「共 12 条、只翻到 10 条」。`DELETE` 刻意不先查资讯是否存在：来源站下架后「取消收藏」不该被 404 卡住。契约新增 2 path + 3 schema，`ContractDriftTest` 已登记；`check-contract` **74 path / 132 $ref / 112 schema**。后端 **500 通过 / 0 skipped**（新增 6 条真库 IT：401 / PUT 幂等 / DELETE 幂等 / 404 / 排序分页 / 双用户隔离）。**已发版**（2026-11-07 20:30，`b34`）；客户端（#452 只读骨架）按 `article_favorite_data_source.dart` 文件头三步接 remote。 |
| 第 31 批 · 算法线与错误语义（11-06，7 提交） | #467（#403 七项表态）/ #468（回填脚本测试）/ #469（调度池 4）/ #470（导入超时 120s）/ #471（#401 画像）/ #472（#402 推荐）/ #473（#414 资讯关联） | pyxz0 | **#467**：pyxz0 七项表态，第 2 项指出 `work_tag` **没有类别维度**（V7 建表即如此），「genre 1.5 / 普通 1.0」算不出来、也不能硬编码题材名单，建议初版等权 + 权重留 `app_config`；第 4 项 `reasons` 只在显式开关时计算；第 7 项曝光表必须有保留期。只签自己一列。**#468**：`backfill_rating_count.py` 补 13 条离线用例（游标不倒退 / 失败必须冒泡 / `ALL_DONE` 与 `PASS_DONE` 两种空 / `exit 2` / apply 降级），CI 接上 `scripts/tests`（42 passed）——这个脚本出过两次「跑了一夜数没涨」。**#469**：调度池 3→4（第 4 个 `ViewCleanupJob` 04:55 随 #421 加、池没跟），加测试断言「@Scheduled 任务数 ≤ 池大小」。**#470**：导入提交超时与抓取拆开（120s / 30s）——实测满批 500 条 9,513 ms、同批重跑 1,778 ms，生产慢 2–3 倍会压在原 30s 线上，压线即整批重跑。**#471**：`GET /api/me/profile`，三路信号（浏览/收藏/点评）UNION ALL + 内存聚合，权重归一化 -1–1、**负值保留**（低分标签 = 不喜欢）、标签按作品标签数均摊、空画像给空对象 + `mean: null`；路径从草案 `/api/profile` 改 `/api/me/profile`——`AuthFilter` 只拦 `/api/me/**`，照草案挂会匿名可读个人数据。**#472**：`GET /api/me/recommend`，候选取画像权重最高的 8 个正标签（每标签 200 部，走 `work_tag` 索引），全量排除已看/已收藏，负权重照扣，评分质量只认 ≥50 票（复用同一常量）；冷启动走全站高分榜 + `cold_start`；规则 3（时效）与 4（共现）**故意不做**——前者对补番用户是负信号且无曝光数据验证，后者用户量不够。**#473**：`GET /api/articles/{id}/related`，同标签/同分类召回，`JSON_OVERLAPS` 必须配 `CAST(:json AS JSON)`（否则字符串被当 JSON 字符串、永远不重叠且不报错）；**同来源降级为不计分**（同媒体天然同质，噪声大于信息）。**无迁移**、无破坏性契约变更；489 通过 / 0 skipped、pytest 303；**已发版**（2026-11-06 17:20，`b31`） |
| 第 30 批 · 错误语义收口与 VNDB 评分（11-06，2 提交） | #464（#456 VNDB 评分归一）/ #465（#345 405 回归 + Allow + 415） | pyxz0 | **#464**：C6 早把入口定死（`scale != "0-10"` 整条拒收），而 VNDB 适配器一直 `main_rating=None`——不是保守，是让这个来源永远没有评分。补线性 `÷10`：无损可逆（原值 = 提交值 × 10），`DECIMAL(4,2)` 下 90.6 → 9.06 正好两位，不另存原始列；缺失 / ≤0 / >100 按缺失，**不裁剪到边界**（裁剪会把上游尺度错静默写成 10 分）；不用分位——分位要先有全站分布，手里只有按 `rating` 降序抓的有偏子集。跨源分布差异保留 `rating_source`，不假装同分同义。**#465**：zm 的 405（`a923537`）只过编译、没有回归防护——补 3 条真库 IT（405 不退回 500 / 信封是 `METHOD_NOT_ALLOWED` / 与 404 分得开 / 415），顺 RFC 9110 补 `Allow` 头，并把 `HttpMediaTypeNotSupportedException` 从 500 收成 415。**踩到的坑**：改 `openapi.yaml` 枚举时 16 空格缩进被写成 8 空格，YAML 仍"看着像对"，`ContractDriftTest` **9 个 error** 才炸出来。**无迁移**、无破坏性契约变更；461 通过 / 0 skipped、pytest 299；**已发版**（2026-11-06 17:20，`b31`） |
| 第 29 批 · 人物页后端（11-05，1 提交） | #462（#455 `GET /api/persons/{id}`） | pyxz0 | 形状照来源站 `cast_detail()`（`person-id-unification.md` §5 阶段 3）：**按作品合并**，同作品既配音又制作只出一条，`characters` / `roles` 各自成列，评分倒序。键当**不透明字符串**（现在裸数字、切 v3 后是 `bgm:` / `pname:` / `cname:`），切流不改代码；不存在/非法一律 404。读模型用 `UNION ALL` 后 `GROUP BY work_ref`——`LEFT JOIN` 两张关系表在「同作品同人既配音又制作」时会做笛卡尔积、`GROUP_CONCAT` 出重复；分隔符用 `§` 不用逗号（人名里会有逗号）。join `work` 做成人/下架/收录过滤，计数同口径。**已知取舍**：`work_staff` / `work_characters` 没有 person_id 索引，反查是两表全扫（约 22 万行、几十毫秒）；没有迁移号可抢（当时 V31 永久跳过 / V33 留给 #362 / V34 许给 #377/#378）；**b35 的 V36 已补**两条 person_id 索引。**无迁移**，458 通过 / 0 skipped（真库 IT 6 条）；**已发版**（2026-11-06 17:20，`b31`） |
| 第 28 批 · 我的评论（11-05，1 提交） | #459（#449 `GET /api/me/comments`） | pyxz0 | 「发出去就找不回来」的补口：改/删都要先知道 `comment_id`，而客户端除了发布响应那一次再也拿不到。口径按 #449 拍板：内嵌 `WorkSummary`（不扁平给 `work_title`）、除自己删掉的 `deleted` 外都返回（`published`/`pending`/`hidden`，隐藏的直接消失会让用户觉得「我明明发过」）、按会话 `site_key` 隔离、`created_at DESC, id DESC`。**无迁移**——`V18` 的 `idx_ugc_user_created (site_key, user_id, created_at)` 正好是这条访问路径。顺带把「WorkRecord→WorkSummary」抽成 `WorkSummaryMapper`（封面代理 / `rating_count<50` 藏分 / 成人标签剔除），六处共用，避免第二份口径漂移；`work` 允许 null（作品后来不可见时评论正文照常返回）。**踩到的坑**：`ContractDriftTest.everySchemaHasAGuard` 会拦「契约加了 schema 没登记」；`openapi.yaml` 里 4 处早前被脚本吃掉的换行也一并修了。452 通过 / 0 skipped（真库 IT）；**已发版**（2026-11-06 17:20，`b31`） |
| 第 27 批 · 验收脚本与工程卫生（11-05，4 提交） | #448（#447 切流验收脚本）/ #450（scripts CI + 队列文档）/ #451（ROADMAP 状态与基线）/ #452（#377 客户端只读骨架） | riceyu02 | **#448**：`scripts/verify_related_ids.py`，只读（SELECT + GET），验开关 / 数据命中率 / 资讯→作品（拿「原文 id 反推出的 work_id 集合」当白名单，抓**串号**而不只是「非空」）/ 作品→资讯双向；切流前跑明确 `SKIP` 并打基线（300 条资讯 / 634 id，可见命中 28.4% 是撞号、不是进度）；**#450**：`scripts/` 与 `devkit/` 以前除两个专属脚本外**零 CI**，新增 `py_compile` + `devkit/tests`（29 passed / 2.5 s，不依赖 flutter/maven/docker）；**#451**：ROADMAP 自身矛盾（127 行说档期已在库、229 行仍说未导入；441 行说两区块已合、233 行仍说待做），按 `schedule` **2,068 条 / 1,467 条有 `work_id`** 与 #256 已关更正，契约基线 42/87 → **68 path / 118 ref / 99 schema**，迁移基线 → **V1…V32（V31 跳过）**；**#452**：收藏页「作品 / 资讯」分段（默认作品、资讯段不提前请求）、独立数据源 + mock + 四态、复用 `ArticleCard`，新增 5 项 + 既有收藏 36 项全过。**无迁移、无契约改动** |
| 第 26 批 · 资讯↔作品双向（11-05，2 提交） | #442（#409 作品→资讯反查 `GET /api/works/{work_id}/articles`）/ #443（#408 服务端 `related_works`） | pyxz0 | 数据侧把 `related_work_ids` 写成 subject_id（#422 撤映射表）后，后端只剩「一次 IN 解析」。两个方向共用运行期开关 `article.related_ids_semantic`（`app_config`，缺省 `content_id` = 关）：切流前用 content_id 当 subject_id 匹配会把**别的作品**挂上来且不报错（V28 实测两套号按数值 JOIN 得 3,015 条假匹配）。**踩到的静默坑**：`JSON_CONTAINS` 对类型敏感，`["11972"]`（Java 导入）与 `[11972]`（数据侧从 SQLite 读出的整数）不相等，两种都得匹配。`related_works` 走单独的 `ArticleDetailAssembler`（否则与 `WorkService` 循环依赖），保留来源站原序、滤掉已下架/成人。**无迁移**，448 通过 / 0 skipped（真库 IT）；开关默认关，**已随 `b31` 发版**——线上行为仍与合入前一致（开关关着），等数据侧切流后改一条配置即生效 |
| 第 25 批 · 浏览打点（11-04，2 提交） | #421（`V32` + `POST /api/me/views` + 90 天清理）/ #423（注销清浏览） | pyxz0 | 画像四路信号里唯一缺失的那一路（#401 拍板：采集点 B、有界行、90 天、迁移号 V32）。表 `(user_id, work_id)` 一行 + `view_count`，`last_viewed_at` 建索引（清理是范围删除）；打点走 `AuthFilter`，公开详情路径零额外成本。发版：V32 **239 ms**、启动 7.08 s、冒烟 7/7，实测 401 / 204 / 204 / 404 与 `view_count=2`。**冒烟顺带发现真 bug**：注销账号后浏览行还在——改成监听 `AccountDeletedEvent` 物理删，重新发版后实测注销即清空 |
| 第 24 批 · 相关推荐按匹配度排（11-04，1 提交） | #416（`3848e714`） | pyxz0 | `findRelated` 从「纯评分」改成「共享标签数 → 评分决胜」：`work_tag` 按 tag 分组计数当匹配度（实测 0.06 s，比在 `work.tags` 上逐元素求交集的 0.30 s 快 5 倍）；收口关闭时退回 JSON 召回 + 左连打分。**踩到一个静默坑**：`JSON_TABLE` 的列不写 `CHARACTER SET utf8mb4`，中文标签一条都匹配不上且查询不报错。生产发版：无迁移、启动 6.5 s、冒烟 7/7；《高达》的相关推荐由「9.2 分的无关作品」变成「8.3 分的 Code Geass / 7.9 的闪光的哈萨维」这类同系列，耗时 44–74 ms |
| 第 23 批 · 深页基线复测（11-04，1 提交） | #399（ROADMAP §8.4 按 18,676 条重测） | pyxz0 | 「第 11000 页 490ms」是 55.6 万条时代的历史值。现值：默认排序最后一页 **120 ms**，`sort=rating` 最后一页 **381–662 ms**（过滤列不在索引里、深偏移全靠回表）。结论仍不触发键集分页，备用方案（覆盖索引）记在 #384 |
| 第 22 批 · 人物键迁移预案 + 回填续跑（11-04，2 提交） | #396（人物键存量迁移，squash 后 `287e61c`）/ #395（回填游标，squash 后 `e13ea1f`，含 #394 的续跑修复；#394 已说明并关闭） | pyxz0 | `#396` 纯文档：19,399 people + 150,453 staff + 75,745 cast **全是裸数字键**，v3 一上线就分叉，写清两条路、发版顺序硬约束与对账基线 **0/0/0**。`#395` 把回填脚本的两个坑一起修掉（队列不前进 + 静默失败被当成跑完），空结果分 `PASS_DONE` / `ALL_DONE`。**脚本不进 jar，不需要发版**；生产实跑一轮 **+1,847 行**（14,356 → 16,203），装到 `/opt/otaku/data/backfill_rating_count.py`（sha256 与 main 一致） |

## 3. 合并后动作

### 已完成

- [x] 前三批源 PR 全部关闭（内容在各批整合 PR 里）
- [x] W1.5 D3 实现（#143）：列表透出 `source` + 封面来源角标
- [x] W1.4 渲染边界自动化（#168 / #169）：封面三态、档期季度切换、未收录条目
- [x] **远端分支清理**（2026-10-26，判据与记录见 §3.1）
- [x] **main 上后端全量校验**：`mvnw test` 209 通过 / 0 失败（含连库集成，`IT_DB_PORT=3307`）
- [x] **W1.3b 拍板并落地**（2026-10-27）：zm 定为「现在做」，token 跨账号转移按原实现
      （换账号时旧行立即失效，避免通知落锁屏）。#190 已合 `35004de`，迁移改号到
      `V11__user_device.sql`（V10 被站主后台占用），线上实测 401 / 201 / 204 正常。
- [x] **W1 三条红线全部落地**：年份筛选 `4c1f3f9`、标签词表 `842f443`、设备令牌 `35004de`
      （见 #95 里 zm 2026-10-26 的逐条答复与 pyxz0 2026-10-27 的收尾评论）。
- [x] **#240 UGC 七项上线**（10-29）：B1 评论 → B2a 开关与后台审核 → B2b 举报与先审后发
      → B2c① 导出 → B2c② 回复 → B2c③ 留存清理与站点下线清单 → B2c④ 编辑；
      迁移 V18–V22，生产逐项端到端冒烟后清数据。
- [x] **#249 作品软删**（V17）：内部端点 + 四面对外过滤 + 复活语义；`DeletionIntegrationTest` 7 条。
- [x] **#271 people 补人**：`work_staff` / `work_characters` 的悬空 `person_id` 19,399 → **0**，1.6 秒。
- [x] **#270 标签索引**：`work_tag(work_ref)` 补索引，全量 18,828 部导入 4,499s → **90.9s**。
- [x] **#273 别名脏值清零**：6,597 行置 `[]`（先备份到 `work_alias_junk_273`），全库 junk=0。
- [x] **#278 锁冲突重试**：撞唯一键与死锁同路重试，避免合法记录被判 `INTERNAL_ERROR`。
- [x] **#286 指标端点**：`/actuator/prometheus` 复用内部令牌，公网实测 401、`health` 保持 200。
- [x] **#195 备份恢复演练（第一次真做）**：53.6MB dump → 独立库恢复 35.8s，逐表与生产一致。
- [x] **封面白名单事故修复**（10-30，PR #298）：加 `app.ugc.retention` 时把 cover 段的
      `allowed-hosts` 挤进 `app.ugc` → 全站封面 404 **55 分钟**（health 仍 UP）。
      修复 + `ApplicationYamlStructureTest`（防配置结构错位）+ `scripts/post-deploy-check.sh`
      （7 项发版冒烟，规程见 `deploy-production.md` §6.1）。

### 待办

- [ ] **W1.4 主观观感走查**：动效与配色，要人和屏幕；自动化能覆盖的六条已全绿
      （见 [`w1-real-data-probe.md`](w1-real-data-probe.md) §5）。
- [x] **Android 真机走查（第一轮）**：10-28 已在 Redmi 真机跑完，14 项通过 / 2 处修复 /
      **4 项被外部条件阻塞**（见 [`real-device-acceptance-2026-10-28.md`](real-device-acceptance-2026-10-28.md) §3）：
      通知送达与重启重注册（后端 `/api/schedule` 零数据）、站点登录完整闭环（需真实测试账号）、
      厂商推送通道（本轮范围外）。**不算完全收口**，但阻塞点都不在代码里。
      2026-11-01 复核：前两项**已失效**——档期数据早已在库（`/api/schedule?season=202610` 有真实条目），
      且「追番提醒」随 #302 下线（`app-client/lib` 无 reminder 代码），没有可走查的对象。
      真机侧真正剩下的只有「站点登录闭环」，仍等一个站点测试账号。
- [x] **客户端全量校验**：`flutter analyze` → `flutter test` → `build apk --debug`；
      最近一次记录是 **391 通过 / 0 失败**（2026-10-30 @ `4334a44`，#302 分支独立跑，based on `af8b3d5`；
      含 #299 带来的 `site_login_error_test.dart` 6 项）。比 10-29 的 385 多 6 项，
      少 0 项——追番提醒的 13 项测试是随功能一起下线的，不计入。
      2026-10-31 又跑了一次 `devtest.py --all`（三栈）：Java 331 / Dart 391 / Python 无失败，全部通过。
- [x] **外观实验定为「默认关」**（2026-10-31，真机对比后拍板）：#302 里的
      「跟随系统取色（Material You）」与「玻璃质感」两个开关**保持默认关闭**——
      关掉即发布版的品牌蓝 + 实心卡片。真机开过一次玻璃质感（背景渐变 + 底栏半透明，
      文字仍可读），效果可用但不作为默认，留给想开的人在 设置 → 外观 里自己开。

## 3.1 分支清理记录（2026-10-26）

**判据**（两条任一成立即可，且不碰有开放 PR 的分支）：

1. `git merge-base origin/main origin/<b>` 存在，且 `git diff --name-only <base>..origin/<b>` 为空
   → 分支是 main 的祖先，内容 100% 在 main（merge commit 合入的那一类）；
2. 否则取该分支自 merge-base 起改动过的文件集，`git diff --quiet origin/main origin/<b> -- <files>`
   为空 → 分支版本与 main 逐字节一致（squash 合入的那一类，祖先关系查不出来）。

清掉的是四类：已合入的 `feat/*` 与 `fix/*`（含 #102/#109/#110/#116/#121/#123/#128/#130/#168/#177 等）、
已合入的 `docs/*` 索引与方案分支、三批整合分支 `ci/batch1/2/3`、演练与临时分支
`ci/merge-train-2026-10-23` / `ci/train-recheck-1024`。

**保留 5 条**（不是漏了）：

| 分支 | 原因 |
|---|---|
| `chore/android-dev-network` | 安卓真机联调用（#98 关闭未合），等真机走查一起处理 |
| `docs/identity-auth-endpoint-playbook` | #135 关闭未合，内容部分被 #141 取代；**zm 的分支，留给他判断** |
| `docs/ironlaw-align-reality` | #150 关闭未合，状态被 #163 重写覆盖；zm 的分支 |
| `docs/release-year-contract-sync` | #99 / #63 关闭未合；zm 的分支 |
| `docs/site-feature-adaptation` | #133 关闭未合；zm 的分支 |

### 2026-10-27 盘点（当前 16 条远端分支）

按同一判据重扫，**11 条可以直接删**——内容已 100% 在 main：

- 与 main 逐字节一致（8 条）：`chore/ignore-android-build`、`feat/backend-device-tokens`、
  `feat/backend-work-year-filter`、`feat/console-phase2-144`、`feat/open-hardening-188`、
  `feat/site-lifecycle-144`、`feat/tags-endpoint-208`、`tune/cover-rate-burst`；
- 分支旧、无独有内容（3 条）：`deploy/live-2026-10-27`、`docs/fix-backup-cron`、
  `feat/site-owner-console`。⚠️ `#203` 是 **closed 不是 merged**，但它的修复已由
  #209 的 `d3f8868` 覆盖进 main——这正是「判断进没进只能看代码，不能看 PR 标记」的又一例。

⚠️ 判据只能用「**该分支改动过的文件**在 main 里是否一致」：两点 `git diff main..branch`
会把「main 后来新增的内容」也算成差异（看着像未合），三点 `git diff main...branch` 又漏掉
squash 合入的那一类。两种直觉都会骗人。

保留 5 条：上表 5 条（#219 / #220 的分支在合并后已删）。

### 2026-10-29 盘点（本地 13 条未合并到 main）

判据同 §3.1。结论：**没有「未收口」的内容**——13 条全是已合未删，或停在合并前的旧版。

| 分支 | 判定 |
|---|---|
| `feat/metrics-endpoint-286` / `feat/people-shell-271` | 与 main **逐字节一致**（10-29 当天合完）→ 可直接删 |
| `feat/device-tokens-integrated` / `pr190` | #190 已合（`35004de`），分支停在合并前 |
| `pr193` / `pr203` | #193 已合；#203 关闭，内容由 #209 覆盖 |
| `feat/site-owner-console` / `feat/site-login-exchange` / `feat/work-rich-fields-250` / `feat/work-relations-255` | 对应 #144 一期 / #242 / #250 / #255 均已合，分支为合并前旧版 |
| `perf/tag-vocabulary-cache`（**#230 closed**） | `TagCache` + `TagService` 缓存**已在 main**；线上实测全量 `/api/tags` 170ms（冷启 410ms），缓存生效 |
| `ci/deploy-smoke`（**#202 closed**） | `deploy-lint.yml` 的 `stack` job（起栈 → 造数 → 备份 → 恢复比对 → monitor）**已在 main**（485 行） |
| `docs/fix-tls-bootstrap-order`（**#205 closed**） | main 的 §4.6 已是修正后的顺序（讲清「鸡生蛋」并要求先跑 `init-letsencrypt.sh`） |

⚠️ **#202 / #205 / #230 又是「closed 但内容在 main」**，与 #203 同一类。
三个 PR 都没有关闭说明——判「进没进」只能看代码，这条规矩已经踩到第四、五、六次了。

### 2026-10-30 盘点（远端 46 条 / 本地 91 条）

判据同 §3.1，另加一条更准的：**`git cherry origin/main <b>`**（按 patch-id 比对，
不看祖先关系也不看 PR 标记）。本次 46 条远端分支里 **32 条内容已在 main、可直接删**（#302 合入后重扫为 **34 条**，
新增 `feat/ui-polish` 与 `feat/site-login-errors-238`）：

- 提交全在 main 祖先链（12 条）：`docs/deploy-long-task-notes`、`docs/pq-296`、
  `feat/backend-device-tokens`、`feat/backend-work-year-filter`、`feat/console-phase2-144`、
  `feat/mobile-bottom-nav`、`feat/open-hardening-188`、`feat/site-lifecycle-144`、
  `feat/tags-endpoint-208`、`feat/work-staff-characters-256`、`perf/tag-vocabulary-cache`、
  `tune/cover-rate-burst` 等；
- patch-id 等价已在 main（20 条）：`chore/android-dev-network`（⚠️ 10-27 判为「保留」，
  现已合入，可删）、`chore/ignore-android-build`、`deploy/live-2026-10-27`、
  `docs/alias-coverage-273`、`docs/rich-fields-tier-a`、`docs/ugc-dayone-positioning`、
  `feat/metrics-endpoint-286`、`feat/people-shell-271`、`feat/site-owner-console`、
  `feat/soft-delete-249`、`feat/ugc-comments-240`、`feat/ugc-export-240b2c`、
  `feat/ugc-moderation-240b2`、`feat/ugc-report-240b2b`、`feat/work-relations-255`、
  `fix/alias-empty-shell-273`、`fix/contract-java-skeleton`、`fix/cover-source-badge-stack`、
  `fix/import-lock-retry-278`。

**保留 9 条未收口**（有独有提交且内容不在 main，逐条核对后才敢动）：

| 分支 | 原因 |
|---|---|
| `docs/identity-auth-endpoint-playbook` / `docs/ironlaw-align-reality` / `docs/release-year-contract-sync` / `docs/site-feature-adaptation` | 方案分支，状态已被 #141 / #163 / #99 覆盖；**zm 的分支，留给他判断** |
| `docs/fix-backup-cron` | 1 提交未进 main，内容与 #209 有重叠 |
| `feat/cover-backfill` | 封面回填长任务（#288）仍在跑，分支跟着任务走 |
| `feat/site-login-exchange` | #242 站点 secret，等外部输入 |
| `feat/work-rich-fields-250` / `fix/work-tag-index-270` | 对应功能已合入，分支停在合并前的旧版（squash 类，祖先关系查不出来） |

**本地 91 条分支**里绝大多数同样已合（`git cherry` 判定内容已在 main），可批量删；
另有 11 个 worktree 占着磁盘（主目录 `D:/otaku` 之外：`D:/otaku-256`、`-b3`、`-b4`、`-deploy`、
`-fix-cover`、`-home`、`-mq`、`-train2`、`-ui`、`-wt2`），逐条核对后再清。

### 2026-11-05 盘点（远端 67 → 10）

- **判据**：PR 已合并，**且**分支最后一次提交 ≤ 该 PR 的 `merged_at`——合并后又被推过新提交的分支不删
  （那种分支上的东西可能没进 main）。57 个候选全部满足，0 个例外。
- **删 58 条**（57 条已合并 + 刚合的 #448 分支），逐个 `DELETE /git/refs/heads/...` 全部 204；
  同时**打开 `delete_branch_on_merge`**，以后合 PR 自动回收。
- **保留 10 条**：`main`；`feat/people-prefix-keys` 与 `docs/person-id-contract-362`
  （#362 / #398 栈式 PR 的 head + base，删了 PR 直接失效）；6 条「PR 关闭但未合并」
  （`docs/article-related-works-mapping-408` 是 #422 要留的证据链，其余 5 条待人工判断）；
  `fix/backfill-rating-cursor`（从无 PR）。
- ⚠️ **两个判断口径的坑**：squash 仓库**不能**用 `git diff main...branch` 判断分支是否已合
  （三点 diff 从 merge-base 起算，恒有差异，67 条里 56 条会被误判）；也不能用
  `GET /pulls?state=closed` 列表里的 `merged` 字段（**恒为 false**），要用 `merged_at`。

## 4. 会踩到的四个坑

1. **squash 合并会让 stacked PR 的 base 悬空**：#122 被 squash 进 `feat/client-home` 后，
   原分支 `feat/client-recent-views` 不再前进 —— #123 当时就卡在这儿。
2. **`#107` 给 `WorkDataSource.fetchWorks` 加了 `String? tag`**：测试桩必须同时带上这个形参，
   否则单 PR 绿、合起来 `flutter analyze` 报 `invalid_override`。
3. **`#116` 分支里重复带了 #111 的两份内容**（ROADMAP 的 W1 节、`sort_related_parity_test.dart`）：
   合并时要人工取较新的一版。
4. **桌面侧栏的序号是三处共管**：`selectedIndex` / `onDestinationSelected` 的 switch / `destinations`
   必须一起改，否则「点侧栏跳错页」而编译与测试全绿。

## 5. 验证基线

| 区块 | 结果 | 时间 / 提交 |
|---|---|---|
| `backend-java` | `mvnw test` **584 通过 / 0 失败**（真库 IT，`IT_DB_PORT=3307`；含 #527 的 15 条 parity/校准与 #545 的 4 条称号用例） | 2026-11-08 @ `c198895`（第 43 批记录） |
| `backend-java`（上一基线） | `mvnw test` **565 通过 / 0 失败**（真库 IT） | 2026-11-08 @ `2983132`（第 42 批记录） |
| `backend-java`（更早） | `mvnw test` **561 通过 / 0 失败**（真库 IT） | 2026-11-08 @ `915d173`（第 41 批记录） |
| `backend-java`（更早） | `mvnw test` **549 通过 / 0 失败**（真库 IT） | 2026-11-08 @ `cff95b4`（第 40 批记录） |
| `backend-java`（更早） | `mvnw test` **548 通过 / 0 失败**（真库 IT） | 2026-11-08 @ `0e8a683`（第 39 批记录） |
| `backend-java`（更早） | `mvnw test` **546 通过 / 0 失败**（真库 IT） | 2026-11-08 @ `6156f6e`（第 38 批记录） |
| `sync-python` | `pytest` **303 passed**（#470 新增 4 条） | 2026-11-06 @ `0c95472`（#470 记录） |
| `backend-java`（第 34 批） | `mvnw test` **511 通过 / 0 失败**（真库 IT） | 2026-11-07 @ `e561c87` |
| `backend-java`（更早） | `mvnw test` **367 通过 / 0 失败**（本地跳过 153 条集成；CI 起真库全跑） | 2026-10-31 @ `4df856f`（#329 记录） |
| `backend-java`（上一基线） | `mvnw test` **301 通过 / 0 失败**（含连库集成，`IT_DB_PORT=3307`） | 2026-10-29 @ `1674698`（#294 记录） |
| `app-client` | `flutter test` **385 通过 / 0 失败**；analyze 干净 | 2026-10-29 @ `30d1dfe`（#296 记录，含新增 13 项；**补上了 10-25 之后的欠账**） |
| `app-client`（#302 分支） | `flutter test` **391 通过 / 0 失败**；analyze 干净 | 2026-10-30 @ `4334a44`（#302 + #299 的两个提交；分支独立跑） |
| 三栈全量（`devtest.py --all`） | Java **331** 项（153 跳过，无 `IT_DB_PORT`）/ Dart **391** 项 / Python 无失败 → **全部通过** | 2026-10-31 @ `cc43337` |
| `app-client`（P5 构建链） | `build_site.sh` 默认路径 debug + release 各构建一次通过、品牌自检命中；覆盖路径用临时站反证 | 2026-10-27 @ `28a7d99` |
| `sync-python`（上一基线） | `pytest` **274 passed** | 2026-10-29 @ `d1ab96c`（#276 记录） |
| 契约 | `ContractDriftTest` 全绿；`python scripts/check-contract.py` → **72 path / 129 `$ref` / 109 schema** | 2026-11-06 实测（历史基线：69/123/103 → 68/118/99 → 42/87） |
| 迁移 | `V1…V32` 已在生产库跑过（V17 软删、V18–V24 UGC、V25–V27 成人过滤与运行期配置、**V32 浏览采集**）；**V31 从未应用、已被跳过** | 2026-11-05（V32 随 #421 发版，迁移 239 ms） |

## 6. 历史快照：2026-11-01 01:10 的开放 PR（**现已全部合入**）

> 截至 2026-11-05 快照，当时开放 PR 仅 **#362 / #398**；**两者已于 2026-11-06/07 合入 main**，本节所记开放 PR 现已全部合入。本节保留，是因为下面两个坑值得记：
> #296 的预存在红、评分回填的两个静默失败。**表格本身不再作为待办清单**。

| PR | 主题 | 状态 |
|---|---|---|
| **#320** | 本文件：记客户端发版（1.1.3 / 1.1.4）、E9–E14 进度、补第 18 批 | riceyu02；改的就是本文件 |
| **#323** | 最近浏览独立二级页 + 单条删除与撤销 | riceyu02；CI 全绿、clean |
| **#325** | 设置页图片缓存计入用量 + 列表预取下一页封面 | riceyu02；CI 全绿、clean |
| **#343** | 三处文档失真按实测改正（档期已有 / 提醒已下线 / 发版示例还用 debug） | riceyu02；纯文档 |

按「不代合并别人的 PR」，等各自作者合。
已合（此前记在「剩余」里的）：#301 / #303 进第 12 批，#314 并入第 18 批，#319 已 squash 合入 `4789cbf`。

⚠️ **#296 合进来时顺带修了 main 上两条预存在的红**（`mobile_nav_test`）：一条断言在整页找
`bookmark_border_rounded`、被作品库 AppBar 的同款收藏图标干扰；另一条钉 AppBar 标题「首页」、
而首页改版后标题已换成品牌行。客户端 10-25 之后就没重跑过全量，所以这两条一直是红的没人发现——
**`app-client` 的 `flutter test` 别再攒着不跑**。

**在跑的不是 PR，是数据任务**：
- **封面回填已收工**（11-03）：索引 103,203 条里 filled 90,743 / missing 12,459 / error 1，`pending=0`。
  cron 仍每 4 小时空跑一次（脚本自己打印「没有待补条目，收工」就退出），不影响任何人。
- **评分人数回填有两个独立的坑**（`scripts/backfill_rating_count.py`，11-04 修完实跑一轮后仍有 **67,323** 行未填）：
  1. **队列不前进**：取数没带 `ORDER BY id`，队首是一整段镜像**永久 404** 的条目（实测前 500 条全 404，
     `ORDER BY id` 的 offset 500 之后立刻 200），写不进去就永远留在队首 → 每轮重抓同一段死区。
  2. **静默失败被当成跑完**（#394）：`fetch_rows` 在 mysql 抖动时返回 `[]`，外层把「查不到」当成
     「填完了」直接 `break`，进程再也不续跑。
  修法分别是「带游标取数（`--after-id`）」与「失败冒泡 + 明确的 `ALL_DONE` 信号」；
  两者改的是同一段代码，所以合成一条栈式 PR（基于 #394）落地，避免互相覆盖。
  脚本只读不写时也已验证：`--after-id 0` 给出下一轮游标，越过末尾打印 `PASS_DONE` 并报剩余行数，
  只有全库填完才是 `ALL_DONE`——外层循环不会再纠结「空结果是没数据还是连不上」。
  实测一轮（`--limit 2000 --concurrency 8 --after-id 0`）约 10 分钟、**+1,847 行**（本批 2,000 条里 153 条镜像无数据，留在队列里下轮重试）。

- **评分人数回填已收口**（11-04 20:00，40 轮 / 6 小时）：`rating_count` 从 11,191 补到 **74,685**。
  **对用户可见的部分是全的**——`site_listed=1` 且有评分的 17,856 条里 **17,855 条已填**，
  剩那 1 条（`subject/332503`）镜像本身就是 404。
  剩余 8,840 行全部是 `site_listed=0`（未收录）的存量，随机抽 20 条**全部 404**，不再重试。
  展示口径最终落在 **13,553 展示（≥50 票）/ 4,302 隐藏（<50 票）**，
  也就是说**每四部有评分的可见作品就有一部不再显示分数**——这是 #383 想要的效果，不是异常。
- **新作品不会自己长出票数**：数据集里 `rating_count` 18,828 行只有 105 行有值（上游源库那列基本是空的），
  唯一来源是镜像。所以加了 `04:40` 的增量 cron（只补 `id > 游标` 的新行，没有新行时一条查询退出），
  见 `deploy-production.md` §7「评分人数增量回填」。没有它，新导入的低票作品会一直按「票数未知」显示分数。

**等外部输入 / 已收口**（2026-11-01 更新）：
- **#242 已端到端跑通**（11-01）：真 ticket → `POST /api/auth/site-login` **200** → 带会话
  `GET /api/me/collections` **200**；假票据仍回 401。账号 `site_12` / `xiaosiyou` 可复用于真机走查。
  后端侧可关，剩下的只是客户端接 OAuth（#238）。
- **告警 webhook 已配**（11-01）：`ALERT_WEBHOOK` 写进 `/opt/otaku/backend/.env`（钉钉群机器人，
  关键词 `巡检`）。实测两次：全绿时 `[OK] 告警通道已配置（webhook）`、退出码 0 不发消息；
  制造一次假失败后 `[告警] 已发送到 oapi.dingtalk.com/…`、退出码 1，群里收到。
  monitor.sh 每次运行现场读 `.env`，**不用重启**；换机器人只改这一行。
  同批核过 `OTAKU_UGC_RETENTION_*` / `OTAKU_UGC_MACHINE_*` 仍没有（吃 `application.yml` 默认值），
  `.env.production.example` 有样板，要调再填。
- **仍是外部输入**：**#195** 正式域名（连带 E13 与 `network_security_config` 白名单）。

**已收口**：Issue #132（三个判据）——授权端点＝站主定稿标准 OAuth 授权码（#141）、
归属＝站点观点优先（#141）、数据主来源＝齐平原则（#133 §8）。

**两条别再忘的判断**：
① 方案进 main ≠ 契约生效（#125 / #126 都是「留档待确认」）；
② 契约里新增 schema 必须同时登记进 `ContractDriftTest` 的两张目标表，否则 CI 红（#183 起）。

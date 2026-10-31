# 合并队列与合并后动作清单

> **现用清单。** 每次合并后更新这一份，不再另写。
> 更新于 2026-11-01 01:10，基准 `main = 4789cbf`（第 18 批：#335–#341 已合，并入的 #314 / #319 也已合）。
> 开放 PR **4 个**（§6，含本 PR）；分支盘点停在 10-30（远端 46 条 / 本地 91 条，绝大多数已合未删，见 §3.2），未重数。
> **客户端已发 1.1.3 / 1.1.4（内部测试），E9–E14 只剩 E13 域名与 HTTPS；下载托管实测可用，见 §0.5。**
> 合并权条例仍按 [`project-charter.md`](project-charter.md) §3.5：**CI 全绿 + 不碰红线 + 说清楚，谁都能合（含自合）**。

## 0. 一句话

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

**当前剩 4 个开放 PR**（详见 §6）：#320 本文件、#323 最近浏览、#325 客户端设置与预取、#343 三处文档失真改正
（都是 riceyu02）。#314 / #319 已合，见第 18 批。

在跑的是数据侧长任务：封面回填分片（cron 每 4 小时 4,000 条，
预计 4–5 天，全库封面 48% → 约 85%，见 #288）。**等外部输入**三件：真 ticket（#242 只差这一步）、
告警 webhook（`ALERT_WEBHOOK`，配了才真能收到）、#195 正式域名。W1 客户端侧要人的活只剩：
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
| 第 17 批 · 运维与交付文档（10-31，4 提交） | #331（备份恢复演练）/ #332（巡检告警通道 + 两个脚本 CRLF 修复）/ #333（看板待外部输入）/ #334（UGC 真实响应样张） | pyxz0 | 真实 dump 恢复演练 24 表一致；巡检失败现在能发 webhook（**生产未配地址，仍只进 syslog**） |

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
| `backend-java` | `mvnw test` **367 通过 / 0 失败**（本地跳过 153 条集成；CI 起真库全跑） | 2026-10-31 @ `4df856f`（#329 记录） |
| `backend-java`（上一基线） | `mvnw test` **301 通过 / 0 失败**（含连库集成，`IT_DB_PORT=3307`） | 2026-10-29 @ `1674698`（#294 记录） |
| `app-client` | `flutter test` **385 通过 / 0 失败**；analyze 干净 | 2026-10-29 @ `30d1dfe`（#296 记录，含新增 13 项；**补上了 10-25 之后的欠账**） |
| `app-client`（#302 分支） | `flutter test` **391 通过 / 0 失败**；analyze 干净 | 2026-10-30 @ `4334a44`（#302 + #299 的两个提交；分支独立跑） |
| 三栈全量（`devtest.py --all`） | Java **331** 项（153 跳过，无 `IT_DB_PORT`）/ Dart **391** 项 / Python 无失败 → **全部通过** | 2026-10-31 @ `cc43337` |
| `app-client`（P5 构建链） | `build_site.sh` 默认路径 debug + release 各构建一次通过、品牌自检命中；覆盖路径用临时站反证 | 2026-10-27 @ `28a7d99` |
| `sync-python` | `pytest` **274 passed** | 2026-10-29 @ `d1ab96c`（#276 记录） |
| 契约 | `ContractDriftTest` 全绿（42 path / 87 ref） | 2026-10-28（#258 补齐 Java 形状骨架后 CI 会真跑） |
| 迁移 | `V1…V27` 已在生产库跑过（V17 软删、V18–V24 UGC、V25–V27 成人过滤与运行期配置） | 2026-10-31 |

## 6. 剩余开放 PR（2026-11-01 01:10 核对）

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

**在跑的不是 PR，是数据任务**：封面回填分片（`cron 17 */4 * * *`，4,000 条/片，见 #288）。

**等外部输入**（2026-10-31 更正，别再看旧结论）：
- **#242**：站点 secret **10-29 已注入生产**，`site-login` 对假票据回 401（不再是 503），只差一张**真 ticket** 走一次端到端；
- **告警 webhook**：巡检失败现在能发，但生产没配 `ALERT_WEBHOOK`，所以仍只进 syslog（服务器没有 MTA）。
  2026-11-01 上服务器核对过 `/opt/otaku/backend/.env` 的键名：`ALERT_WEBHOOK` **确实不存在**，
  `OTAKU_UGC_RETENTION_*` / `OTAKU_UGC_MACHINE_*` 也都没有（吃 `application.yml` 默认值）。
  `.env.production.example` 已有这批键的注释样板，填进去再重启即可；
- **#195**：正式域名。

**已收口**：Issue #132（三个判据）——授权端点＝站主定稿标准 OAuth 授权码（#141）、
归属＝站点观点优先（#141）、数据主来源＝齐平原则（#133 §8）。

**两条别再忘的判断**：
① 方案进 main ≠ 契约生效（#125 / #126 都是「留档待确认」）；
② 契约里新增 schema 必须同时登记进 `ContractDriftTest` 的两张目标表，否则 CI 红（#183 起）。

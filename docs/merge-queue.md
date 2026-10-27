# 合并队列与合并后动作清单

> **现用清单。** 每次合并后更新这一份，不再另写。
> 更新于 2026-10-27 23:25，基准 `main = 28a7d99`（#219 P5 一键出包、#220 文档收口已合入）。
> 开放 PR **0 个**；远端分支 16 条，其中 11 条是「已合未删」（判据与记录见 §3.1）。
> 合并权条例仍按 [`project-charter.md`](project-charter.md) §3.5：**CI 全绿 + 不碰红线 + 说清楚，谁都能合（含自合）**。

## 0. 一句话

**后端这一轮全部落地，功能面没有在飞的东西。** 10-27 一天合入 #193（年份筛选）/
#190（设备令牌）/ #208+#212（标签词表）/ #144 二期（站主名单、审计）/ #217+#218（限流与 CORS），
均已在 `154.8.194.198:8080` 上线。`deployment-schedule.md` §4.1 里那三个「卡在分支冲突」的
PR 已全部闭环：#193 / #190 已合，#203 关闭且内容由 #209 覆盖。

**当前没有开放 PR。** P5 的一键出包已进 main（#219：`sites/<site>/site.conf` +
`build_site.sh` / `.ps1`，默认与覆盖路径都实测过）。
W1 剩下的两格都不在代码里：**主观观感走查**（动效/配色，要人 + 屏幕，清单见
[`w1-real-data-probe.md`](w1-real-data-probe.md) §5.1）与 **Android 真机走查**（要设备）。

**查 PR 先看评论区**：D3 卡过一整天，最后发现 @zhengmin486 早在 #120 的评论里放行了。
「待三人确认」这个标签不一定反映最新讨论进度。

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

每批整合 PR 合入后，**源 PR 已逐条关闭**并留了「已随 #NNN 合入」的说明。

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

### 待办

- [ ] **W1.4 主观观感走查**：动效与配色，要人和屏幕；自动化能覆盖的六条已全绿
      （见 [`w1-real-data-probe.md`](w1-real-data-probe.md) §5）。
- [ ] **Android 真机走查**：桌面实机走查已完成（[`stage2-acceptance.md`](stage2-acceptance.md)），
      按章程 §4 还不算收口。
- [ ] **客户端全量校验**：`flutter analyze` → `flutter test` → `build apk --debug`；
      最近一次记录是 305 通过（2026-10-25），本轮只改后端与文档，未重跑。

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
| `backend-java` | `mvnw test` **209 通过 / 0 失败**（含连库集成，`IT_DB_PORT=3307`） | 2026-10-27 @ `8874ede`（#216 记录） |
| `app-client` | `flutter test` **305 通过**；analyze 干净（#219 只加脚本，未重跑全量） | 2026-10-25 @ `7a9e507` |
| `app-client`（P5 构建链） | `build_site.sh` 默认路径 debug + release 各构建一次通过、品牌自检命中；覆盖路径用临时站反证 | 2026-10-27 @ `28a7d99` |
| `sync-python` | `pytest` **174 passed** | 2026-10-27 @ `fe06a03`（#213 记录） |
| 契约 | `ContractDriftTest` 全绿（42 path / 87 ref） | 2026-10-27（#216 记录） |
| 迁移 | `V1…V12` 已在生产库跑过（V11 设备令牌、V12 审计） | 2026-10-27 |

## 6. 剩余开放 PR

| PR | 主题 | 状态 |
|---|---|---|
| — | 无开放 PR | #219 / #220 已于 2026-10-27 合并 |

**已收口**：Issue #132（三个判据）——授权端点＝站主定稿标准 OAuth 授权码（#141）、
归属＝站点观点优先（#141）、数据主来源＝齐平原则（#133 §8）。

**两条别再忘的判断**：
① 方案进 main ≠ 契约生效（#125 / #126 都是「留档待确认」）；
② 契约里新增 schema 必须同时登记进 `ContractDriftTest` 的两张目标表，否则 CI 红（#183 起）。

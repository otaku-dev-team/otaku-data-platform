# 合并队列与合并后动作清单

> **现用清单。** 每次合并后更新这一份，不再另写。
> 更新于 2026-10-24 03:50，基准 `main = 1f602e4`（#141/#142 拍板记录、#148 档期页侧栏修复都已合入；Issue #132 三个判据已收口关闭），开放 PR **5 个**（见 §6）。
> 合并权条例如期生效：**CI 全绿 + 不碰红线 + 说清楚，谁都能合**（[`project-charter.md`](project-charter.md) §3.5）。

## 0. 一句话

前三批（共 11 个功能 PR）已经全部进 main，**客户端那条主链没有内容卡在 PR 里了**；
W1.5 的最后一格 D3 也已落地（#143，列表透出 `source` 让跨源同名记录可分辨）。
剩下的悬而未决项都是**文档 / 待决策**：#125 人物页方案、#126 通知方案、#127 资讯契约、
#133 站点特色功能、#135 授权端点问需、#141 / #142 zm 的定位与待决清单记账。

**查 PR 先看评论区**：D3 卡了一整天，最后发现 @zhengmin486 早在前一天就在 #120 的评论里放行了。
「待三人确认」这个标签不一定反映最新的讨论进度。

**如果还要合功能 PR**：先看 §1 的栈关系是否还存在——现在 main 上只剩 docs 类 PR 互相独立，直接合即可。

## 1. 栈关系（`merge-base --is-ancestor` 实测，已全部落库）

```
article-sync (#110)        ⊃ schedule-sync (#105)
collection-offline (#116)  ⊃ tag-filter (#107) ⊃ offline-cache (#103)
client-home (#121)         ⊃ 上述全部（原基于演练分支 ci/merge-train-2026-10-23）
search-and-settings (#123) ⊃ client-home (#121)
reminders (#128)           ⊃ search-and-settings (#123)
filter-links (#130)        ⊃ client-home (#121)
```

三种「叠」的后果完全不同：

- **合栈顶、关底座** → 零冲突（推荐）；
- **先合底座、再合栈顶** → 重复应用，实测 `#105 → #110` 产生 **18 处冲突、7 个文件**；
- **合了底座却不合栈顶** → 功能进去了，但 PR 列表里那个栈顶会一直显示「冲突」。

## 1.5 合并方式会改变顺序策略（先看这一节）

`main` 上两种合并方式并存：

- **squash**：单亲提交、标题带 `(#NNN)`，占多数（#119 / #118 / #117 / #115 / #113 …）；
- **merge commit**：`Merge pull request #NNN from …`，最近的有 **#129 / #134 / #136 / #137**（功能整合批一律用它，保留被整合分支的提交历史）。

这决定了栈内 PR 该怎么合：

| 合并方式 | 先合底座（#105 → #110） | 说明 |
|---|---|---|
| **squash** | 冲突（实测 18 处 / 7 文件） | squash 产生**新提交**，底座的提交并未进入 main 的祖先链，上层的 diff 仍包含底座改动 → 重复应用 |
| **merge commit** | 安全 | 底座的提交成为 main 的祖先，`merge-base` 自动前移，上层 diff 只剩自己的改动 |

**结论（已实测验证）**：前三批都用 merge commit 入 main，因此第二批、第三批的栈顶（`client-home` 及其上层）**不需要 squash 式 rebase**，
但因为它们原本发源于「演练分支 / 已消失的功能分支」，仍需 `git rebase --onto main <旧 base> <分支>` 把发起点搬到 main ——这只是搬起点，冲突极小（第三批整批只有 1 处）。

> 合并权限：2026-10-24 起 **三人平等、可自合**（[`project-charter.md`](project-charter.md) §3.5），不再需要互相指派 reviewer。
> 门槛只有三条：CI 全绿 / 不碰 §3.2 红线 / PR 里写清改了什么与怎么回滚。

## 2. 合并进度（4 批，**已全部完成**）

| 批 | 整合 PR | 合入提交 | 含原 PR | 结果 |
|---|---|---|---|---|
| 第 1 批 · 后端与同步 | [#134](https://github.com/otaku-dev-team/otaku-data-platform/pull/134)（`ci/batch1`） | `ad07012` | #102 / #109 / #110（含 #105） | `mvnw test` 111 / `pytest` 110 通过 |
| 第 2 批 · 客户端主链 | [#136](https://github.com/otaku-dev-team/otaku-data-platform/pull/136)（`ci/batch2`） | `a1f4d1c` | #116（含 #107 / #103）/ #106 / #112 / #114 | `flutter test` **193 passed** |
| 第 3 批 · 客户端栈顶 | [#137](https://github.com/otaku-dev-team/otaku-data-platform/pull/137)（`ci/batch3`） | `ac51dbd` | #121（含 #122）/ #123 / #128 / #130 | `flutter test` **252 passed** |
| 随时 · 文档 | — | `f7f4be9` | #131（本清单）、#138（章程 §3.5 合并权）、#139 / #140（清单收尾） | 文档，不触发 CI |
| 第 4 批 · 文档与呈现适配 | — | `a378772` / `fd1dbeb` / `8bcfe34` / `f534b92` | #143（列表 `source`，含契约同步）/ #111（W1 看板）/ #120（D3 转决策记录）/ #145（客户端能力承载清单） | backend 111 / flutter 258 / pytest 110 |
| 第 5 批 · 拍板落账与验收 | — | `0e80df4` / `15a13a9` / `1f602e4` | #141（授权形态由站点决定）/ #142（C1/D1 记账）/ #148（档期页补侧栏，含 W1.4 桌面走查记录） | flutter 260 / backend 111 / pytest 110 |

每批整合 PR 合入后，**源 PR 已逐条关闭**并在里面留了「已随 #NNN 合入」的说明。

## 3. 合并后动作

### 已完成

- [x] #105 / #103 / #107 / #102 / #109 / #110 / #116 / #106 / #112 / #114 / #121 / #123 / #128 / #130 全部关闭（内容在各批整合 PR 里）
- [x] #121 / #123 / #128 / #130 改基到 main（`rebase --onto`，仅 `desktop_nav_shell.dart` 一处冲突）
- [x] **W1.5 D3 实现**（#143）：列表透出 `source` + 封面来源角标；W1 看板 §8.6 同步（#111）
- [x] `flutter analyze` 干净、`flutter test` **258 passed**、`mvnw test` 111 passed、`pytest` 110 passed

### 待办

- [ ] **删掉已完成使命的功能分支**：`feat/schedule-backend`、`feat/article-backend`、`feat/article-sync`、`feat/schedule-sync`、
      `feat/client-offline-cache`、`feat/client-tag-filter`、`feat/client-collection-offline`、`feat/schedule-client`、`feat/article-client`、
      `feat/rating-sort-clarity`、`feat/client-home`、`feat/client-search-and-settings`、`feat/client-filter-links`、`feat/client-reminders`、
      `ci/batch1` / `ci/batch2` / `ci/batch3`。
      按 ROADMAP §8.1：**涉及别人分支的一律开 PR 交原作者判断**；只有「内容 100% 在 main 的零差异分支」可直接清理并留痕。
- [ ] **`ci/merge-train-2026-10-23` 删掉**：演练完成即废弃，留着会让人以为还有一条在飞。
- [ ] **W1.4 真机走查**：自动化双端一致性已过（记录见 `stage2-acceptance.md`），真机未覆盖——按章程 §4 这条还不算收口
- [ ] **main 上跑一次完整校验**：`flutter analyze` → `flutter test` → `flutter build apk --debug`；`mvnw test`；`pytest`（本地已跑过前三批的组合，CI 上由各批 PR 分别验证）。

## 4. 会踩到的四个坑

1. **squash 合并会让 stacked PR 的 base 悬空**：#122 被 squash 进 `feat/client-home` 后，
   原分支 `feat/client-recent-views` 不再前进 —— #123 当时就卡在这儿（已修）。
2. **`#107` 给 `WorkDataSource.fetchWorks` 加了 `String? tag`**：#106 / #114 的测试桩必须同时带上这个形参，
   否则单 PR 绿、合起来 `flutter analyze` 报 `invalid_override`（两处已在各自分支补好）。
3. **`#116` 分支里重复带了 #111 的两份内容**（ROADMAP 的 W1 节、`sort_related_parity_test.dart`）：
   合并时 ROADMAP 取 8.6 新版、测试取带 `tag` 的那版。
4. **桌面侧栏的序号是三处共管**（第三批实测）：`#121` 要加「首页」，
   `selectedIndex` / `onDestinationSelected` 的 switch / `destinations` 必须**一起改**，
   否则会出现「点了侧栏跳错页」但编译和测试都不报错的情况。

## 5. 验证基线（main @ `ac51dbd`）

> 下表是**当时的运行口径快照**，不是实时值。要拿当前数字跑
> `python scripts/devtest.py --inventory`（测试项数）或 `python scripts/devtest.py --all`
> （真实通过数）。源码里的 `@Test` 数量会随开发增长，与下表不等是正常的。

| 区块 | 结果 |
|---|---|
| `backend-java` | `mvnw test` 111 通过 / 0 失败 / 8 跳过 |
| `sync-python` | `pytest` 110 passed |
| `app-client` | `flutter analyze` 干净；`flutter test` **258 passed**；滚动基准 p50=18.21ms / p95=48.91ms |
| 迁移 | `V1…V9` 逐字节一致，空库跑通 |

## 6. 剩余开放 PR（全部 docs 类，互不冲突）

| PR | 主题 | 状态 |
|---|---|---|
| #125 | 人物页 / 制作公司页 / 详情页富字段的数据链路 | 待确认（数据主来源已定＝齐平原则，可推进讨论） |
| #126 | W1.3 通知：拆本地提醒 / 服务端推送 | 待确认（服务端推送要新端点＝红线） |
| #127 | 资讯接口⑥契约 | 待合（契约变更，走红线流程） |
| #133 | 站点特色功能适配方案（齐平原则） | 待决策 |
| #135 | 身份授权端点问需说明 | 待决策 |

**已收口**：Issue #132（三个判据）——授权端点＝站主定稿标准 OAuth 授权码（#141）、
归属＝站点观点优先（#141）、数据主来源＝齐平原则（#133 §8）。结论已写在 Issue 里并关闭。

**待拍板的两个新条目**（来自 [`client-capability-list.md`](client-capability-list.md) §5）：
① 站点有我们没有的三个筛选（标签词表 / 年份 / 多标签）是否并入 #133 的齐平原则一起落地；
② 服务端推送（#126）现在要不要做。

**W1 侧仍然开着的验收缺口**：W1.4 的 **Android 真机走查**（桌面实机走查已完成，见
`stage2-acceptance.md`「W1.4 桌面实机走查」），以及**真实数据下的桌面渲染走查**
（本轮全程 USE_MOCK 演示数据，要带 `--dart-define=USE_MOCK=false` 连后端再走一遍）。

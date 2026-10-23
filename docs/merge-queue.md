# 合并队列与合并后动作清单

> **现用清单。** 每次合并后更新这一份，不再另写。
> 更新于 2026-10-24 01:50，基准 `main = 3c0bcae`（#129 已合并），开放 PR **20 个**。

## 0. 一句话

客户端那些「已写完但看不到」的功能全卡在合并上：`main` 停在 10-22，代码在 PR 里。
**按下面的顺序合，零冲突；按 PR 编号从小到大合，会造出一批本不存在的冲突。**

## 1. 先看栈关系（`merge-base --is-ancestor` 实测）

```
article-sync (#110)     ⊃ schedule-sync (#105)
collection-offline(#116) ⊃ tag-filter (#107) ⊃ offline-cache (#103)
client-home (#121)      ⊃ 上述全部（它基于演练分支 ci/merge-train-2026-10-23）
```

三种「叠」的后果完全不同：

- **合栈顶、关底座** → 零冲突（推荐）；
- **先合底座、再合栈顶** → 重复应用，实测 `#105 → #110` 产生 **18 处冲突、7 个文件**；
- **合了底座却不合栈顶** → 功能进去了，但 PR 列表里那个栈顶会一直显示「冲突」。

## 1.5 合并方式会改变顺序策略（先看这一节）

`main` 上两种合并方式并存（2026-10-24 观察最近 20 个提交）：

- **squash**：单亲提交、标题带 `(#NNN)`，占绝大多数（#119 / #118 / #117 / #115 / #113 …）；
- **merge commit**：`Merge pull request #NNN from …`，最近的有 **#129**（产品定位，保留了 9 个提交）与 #104。

这决定了栈内 PR 该怎么合：

| 合并方式 | 先合底座（#105 → #110） | 说明 |
|---|---|---|
| **squash** | ❌ 冲突（实测 18 处 / 7 文件） | squash 产生**新提交**，底座的提交并未进入 main 的祖先链，上层的 diff 仍包含底座改动 → 重复应用 |
| **merge commit** | ✅ 安全 | 底座的提交成为 main 的祖先，`merge-base` 自动前移，上层 diff 只剩自己的改动 |

**结论**：栈内的功能 PR 用 **merge commit** 最省事；文档 PR 用哪种都行。
如果坚持用 squash，就必须按「合栈顶、关底座」来做，并在合完后把被包含的 PR 关掉。

## 2. 合并顺序（4 批）

### 第 1 批 · 后端与同步（3 个）

| 顺序 | PR | 分支 | 说明 |
|---|---|---|---|
| 1 | **#102** | `feat/schedule-backend` | 表 `V8__schedule.sql` + 公开接口 |
| 2 | **#109** | `feat/article-backend` | 表 `V9__article.sql` + 公开接口 |
| 3 | **#110** | `feat/article-sync` | **已含 #105**，合它即可；#105 随后关掉 |

> ⚠️ #109 与 #102 都改 `PublicIdGenerator`：保留两个方法（`nextScheduleId` / `nextArticleId`），类注释写全四个用途。
>
> `#105` 是 `#110` 的底座：**squash 就只合 #110 并关 #105；merge commit 则先 #105 再 #110 也干净**（见 §1.5）。

### 第 2 批 · 客户端主链（4 个）

| 顺序 | PR | 分支 | 说明 |
|---|---|---|---|
| 4 | **#116** | `feat/client-collection-offline` | **已含 #107、#103**；合它即可，那两个随后关掉 |
| 5 | **#106** | `feat/schedule-client` | 档期页 |
| 6 | **#112** | `feat/article-client` | 资讯列表 + 详情；侧栏加到 4 项 |
| 7 | **#114** | `feat/rating-sort-clarity` | 无评分沉底 |

### 第 3 批 · 客户端栈顶（4 个，**必须等第 2 批全部进 main**）

> 到这一步同样看合并方式：第 2 批用了 **merge commit**，`#121` 的 `merge-base` 会自动前移到演练分支头，
> **改 base 到 main 即可，不必 rebase**；用了 **squash**，就必须先把它的两个提交 rebase 到 main。

| 顺序 | PR | 当前 base | 合并前要做的事 |
|---|---|---|---|
| 8 | **#121** | `ci/merge-train-2026-10-23` | base 是演练分支，合进去等于白合。**先把两个提交 rebase 到 main，再把 base 改成 main**（W1 侧做，约 10 分钟） |
| 9 | **#123** | `feat/client-home` | 等 #121 进 main 后 rebase 到 main（W1 侧做） |
| 10 | **#130** | `feat/client-home` | 同上 |
| 11 | **#128** | `feat/client-search-and-settings` | 等 #123 rebase 后再 rebase（那个分支已改写过一次，必须先 rebase） |

### 随时 · 文档（6 个，互不冲突）

`#111`、`#120`、`#125`、`#126`、`#127`、`#129`

## 3. 合并后动作（逐条）

- [ ] **#105 关闭**：内容已含于 #110，再合会重复应用。
- [ ] **#103 / #107 关闭**：内容已含于 #116。
- [ ] **#121 rebase 到 main**（两个提交：首页、最近浏览），base 改为 `main`。
- [ ] **#123 rebase 到 main**（两个提交：搜索历史、设置页）。
- [ ] **#130 rebase 到 main**（一个提交：标签跳转 + 清筛选）。
- [ ] **#128 rebase 到 #123 的新 head**（追番提醒）。
- [ ] **删掉 `ci/merge-train-2026-10-23`**：演练完成即废弃，留在那里只会让人以为还有一条在飞。
- [ ] **main 上跑一遍**：`flutter analyze` → `flutter test` → `flutter build apk --debug`；`mvnw test`；`pytest`。

## 4. 会踩到的三个坑

1. **squash 合并会让 stacked PR 的 base 悬空**：#122 被 squash 进 `feat/client-home` 后，
   原分支 `feat/client-recent-views` 不再前进 —— #123 当时就卡在这儿（已修）。
2. **`#107` 给 `WorkDataSource.fetchWorks` 加了 `String? tag`**：#106 / #114 的测试桩必须同时带上这个形参，
   否则单 PR 绿、合起来 `flutter analyze` 报 `invalid_override`（两处已在各自分支补好）。
3. **`#116` 分支里重复带了 #111 的两份内容**（ROADMAP 的 W1 节、`sort_related_parity_test.dart`）：
   合并时 ROADMAP 取 8.6 新版、测试取带 `tag` 的那版。

## 5. 验证基线（复检分支 `ci/train-recheck-1024`，基点 `1ff93b0`）

| 区块 | 结果 |
|---|---|
| `backend-java` | `mvnw test` 111 通过 / 0 失败 / 8 跳过 |
| `sync-python` | `pytest` 110 passed |
| `app-client` | `flutter analyze` 干净；`flutter test` **228 passed** |
| 迁移 | `V1…V9` 逐字节一致，空库跑通 |

# 预合并演练记录（2026-10-23）

> 分支 `ci/merge-train-2026-10-23`，**只用于验证「这些 PR 合到一起能不能跑」，不提议合并它本身**。
> 目的：让合并方一次看清顺序、冲突点与验证结果，而不是逐个 PR 合到一半才发现断裂。

## 1. 参与的分支与顺序

| 顺序 | PR | 分支 | 层 |
| --- | --- | --- | --- |
| 1 | #102 | `feat/schedule-backend` | 后端（`V8__schedule.sql`） |
| 2 | #109 | `feat/article-backend` | 后端（`V9__article.sql`） |
| 3 | #105 | `feat/schedule-sync` | sync |
| 4 | #110 | `feat/article-sync` | sync（**基于 #105**） |
| 5 | #103 | `feat/client-offline-cache` | 客户端 |
| 6 | #107 | `feat/client-tag-filter` | 客户端（**基于 #103**） |
| 7 | #106 | `feat/schedule-client` | 客户端 |
| 8 | #112 | `feat/article-client` | 客户端 |
| 9 | #114 | `feat/rating-sort-clarity` | 客户端 |

`feat/article-sync` 与 `feat/client-tag-filter` 本身是叠加分支，所以先合它们的底座，
这两步就是无冲突的。**#116（收藏离线）不在这条链里**——它基于 #107，且当时仍在另一会话里写。

## 2. 三处冲突与解法

### 2.1 `PublicIdGenerator.java`（#102 × #109）

两边各加一个方法（`nextScheduleId` / `nextArticleId`），Javadoc 的注释头也各改了一行。
解法：**都留**，注释头写成「work_id / user_id / schedule_id / article_id」四行合一。

### 2.2 `desktop_nav_shell.dart`（#106 × #112）

两边各加一个侧栏项，`selectedIndex` 与 `switch(index)` 的映射互相顶掉。
解法：侧栏变成四项，顺序固定为 **作品库(0) / 资讯(1) / 收藏(2) / 新番(3)**，
`selectedIndex` 与 `onDestinationSelected` 都按这个顺序重写。

### 2.3 `contents_page.dart` / `work_card.dart` / `work_list_tile.dart`（#107 × #114）

- 卡片与列表行：#107 把它们从 `StatelessWidget` 改成了 `ConsumerWidget`（要 `ref`），
  #114 给构造函数加了 `showMissingRating`。解法：**`ConsumerWidget` + 两个参数都要**。
- 列表页：#107 加了标签筛选条与离线提示，#114 加了「无评分沉底」说明条并改了
  `_buildBody` 的签名。解法：三块都留，顺序为 **标签筛选条 → 离线提示 → 排序说明条 → 列表**；
  说明条放最后是因为它解释的是内容，不该抢在「这是缓存」前面。

## 3. 一处跨 PR 编译断裂（单测发现，编译不报）

`WorkDataSource.fetchWorks` 在 #107 里多了 `String? tag`，而 #106 与 #114 各自的测试桩
还是旧签名 → **两个 PR 单独跑 CI 都是绿的，合到一起 `flutter analyze` 直接报
`invalid_override`**。修复：给两个测试桩补上 `tag` 参数（本分支最后一个提交）。

⚠️ 这条没法提前修到各自的分支上：接口里没有 `tag` 时，测试桩多写一个具名参数同样是
`invalid_override`。所以**合 #107 之后、再合 #106 / #114 时必须带上这条修复**。

## 4. 验证结果（全部在本分支上跑）

| 项 | 命令 | 结果 |
| --- | --- | --- |
| 客户端静态分析 | `flutter analyze` | No issues found |
| 客户端测试 | `flutter test` | **173 passed** |
| 后端测试 | `./mvnw test` | **111 tests, 0 failures**（8 skipped） |
| sync 测试 | `pytest -q` | **110 passed** |
| 迁移链 | 空库启动后端 | `V1…V9` 全部 `success`，`work/article/schedule/work_tag` 等 10 张表就位 |
| 接口 | 空库 `curl` | `/api/schedule`、`/api/articles`、`/api/articles/categories` 均 200 |

迁移用临时库 `otaku_mergetrain_check`（验证后已删除），所以 `V8`、`V9` 是**真的按顺序应用**
而不是「表已经存在所以跳过」。

## 5. 结论

按第 1 节的顺序合，冲突只有三处、每处都是「两边都留」，加上第 3 节那条测试桩修复即可全绿。
反过来（例如先合 #112 再合 #106）冲突规模不变，但 #116 那条链要重新排。

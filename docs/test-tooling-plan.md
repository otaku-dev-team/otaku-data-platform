# 测试工具搬移方案（acgn-test-platform → 本项目）

> 版本 v0.1 ｜ 2026-10-26 ｜ 类型：方案稿，**未改任何代码**
> 货源：`C:\Users\52487\projects\acgn-test-platform`（只读盘点，未改动对方仓库）
> 目的：把那边已经跑通的自动化测试工具，按我们「Java + Python + Flutter」三栈结构重做，
> 减少人和智能体在「改完了该跑什么」上的决策成本与输出阅读成本。

## 一、结论先行

**值得搬的只有一件：改动 → 选跑（`scripts/devtest.py`）。**

acgn 那套测试工具里，真正省事的不是「测试写得多」，而是把一条口头纪律
（「严禁全量，只跑相关文件」）变成一条命令。我们现在的处境和它当初一模一样：

- 三个栈三条命令（`./mvnw test` / `python -m pytest` / `flutter test`），CI 靠
  `paths` 过滤器做到了**栈级**影响判断，**本地没有任何对应物**；
- 于是本地要么凭记忆猜、要么三栈全跑、要么干脆不跑等 CI；
- 智能体更吃亏：它没有「上次的经验」，每次都要重新推断改的文件属于哪个栈、哪些测试覆盖它。

**明确不搬的两块**（不是嫌麻烦，是搬来是负收益）：

| 不搬 | 原因 |
|---|---|
| 应用内测试后台（`/testcases` 用例页 + 批次 + 回归对比，约 900 行） | 它的宿主是 FastAPI + Jinja 管理页面。我们是 Spring Boot 纯 API 后端，没有管理页承载。搬过来等于**为了测试工具先新建一个 Web 站**，再让所有人多一个要登录的后台。内核（只读路由冒烟 + 快照对比）拆成 CLI 即可，见切片 4。 |
| `dev_instances.py` 文件锁 / 端口槽 / git worktree（451 行） | 那套是给「同一台机器开多份、多人共用一台开发机」准备的。我们三人靠 PR 隔离、智能体单工作区串行，冲突来源是 GitHub 分支不是文件锁。装了也不会有人 take/release。 |

顺带捡两个便宜但真省事的：**测试断网守卫**（防止新测试误打真站）、
**仓库根的智能体入口说明**（工具做了没人知道等于没做）。

## 二、货源盘点（acgn 那边到底有什么）

| # | 资产 | 体量 | 干什么 | 对我们的价值 |
|---|---|---|---|---|
| 1 | `scripts/devtest.py` | 290 行 | 按 git 改动选跑测试：AST 解析 import 建映射、一层反向传播、页面模块用路由字面量反查、`--collect` 干跑、`conftest.py` 唯一自动全量 | **高**。直接对应我们最大的决策成本 |
| 2 | `app/runner.py` | 250 行 | 进程内 TestClient 发请求、只比状态码、批次回归对比（六类变化：regression / fixed / unchanged_fail / unchanged_pass / added / missing） | 中。**对比口径设计**值得抄，宿主不要 |
| 3 | `app/case_discovery.py` | 240 行 | 从**已挂载路由表**反推只读 GET 生成冒烟用例；auto 用例只更新不重建（否则回归基线全变「新增/缺失」） | 中。两条经验：端点清单别硬编码；回归对齐要有稳定键 |
| 4 | `scripts/run_regression.py` | 120 行 | 部署后一键：同步用例集 → 执行全部 → 对比上批 → 机器可读退出码（0/1/2） | 中高。**退出码语义**（只有 regression>0 才堵门，missing 不算）可直接沿用 |
| 5 | `app/testing_pages.py` + `cases.py` | 约 660 行 | 上面三个的 Web 外壳（用例增删改查、执行历史、批次对比页） | **不要**。见第一节 |
| 6 | `conftest.py` 的 autouse 夹具 | 30 行 | 全局关掉「按需联网」开关，保证测试不联网 | **高**。我们缺这一层兜底 |
| 7 | 那几份 `docs/*方案*.md` 的写法 | — | 缺口 → 证据 → 切片 → 验收 → 风险 → 拍板 | 借用格式（本文即照此写） |

## 三、我们的真实缺口

| # | 缺口 | 现状证据 | 后果 |
|---|---|---|---|
| 1 | **选跑靠人脑** | 三栈测试规模：Java 19 个测试类 / 127 个 `@Test`、Python 8 个文件 / 110 项、Dart 26 个文件 / 约 260 项。CI 有四份 workflow 各自按 `paths` 过滤，**本地没有等价物** | 改后端跑 Flutter、改 Dart 跑 Maven 是真会发生的；或者干脆三栈全跑，等待时间和输出量都白花 |
| 2 | **跨栈影响没有答案** | 改 `docs/openapi.yaml` 一行，理论上 Java（`ContractJsonShapeTest`）、Python（`tests/test_importer.py`）、Dart（`test/models_test.dart`）三处都该看，实际没人说得清该跑哪几个文件 | 契约改动是最高风险改动，验证覆盖却最随意 |
| 3 | **输出不是给人/智能体读的** | `mvnw test` 默认输出几百行；成功时只需要一行结论，失败时只需要那一条断言 | 智能体要拿几百行 token 换一句「都过了」 |
| 4 | **文档里的数字会过期** | `docs/merge-queue.md:105` 记「`mvnw test` 111 通过 / 0 失败 / 8 跳过」、`:106` 记「`pytest` 110 passed」。111 是当时的运行口径（现在源码里 127 个 `@Test`，其中 3 个 IT 类无 `IT_DB_PORT` 会跳过），数字本身没错，**是没人有办法维护它** | 新人和智能体会把过期数字当基线；acgn 的 README 同时存在「990 多项」和「1066 项 + 5 项已知失败」两种说法，就是这么来的 |
| 5 | **本地测试与真站之间没有硬隔离** | `sync-python` 靠 `tests/conftest.py` 起的本地桩服务（`127.0.0.1`）自觉；没有任何机制阻止某条新测试直接打 `154.8.194.198:8000` | 一次手滑就是一次真实抓取。我们对抓取频率本来就敏感（sync 串行限流 1.67 req/s），测试误打是最不该发生的流量 |

## 四、实施切片

### 切片 1（P0）：`scripts/devtest.py` —— 改动 → 选跑

**一句话**：改完代码敲一条命令，它告诉你「该跑这些」，并直接跑掉，只回结论。

```
python scripts/devtest.py                  # 自动取改动，选跑三栈相关文件
python scripts/devtest.py --collect        # 只列清单和原因，不执行（让智能体先看规划）
python scripts/devtest.py --json           # 机器可读，给自动化/智能体消费
python scripts/devtest.py --all            # 明确全量三栈（人工兜底，慎用）
python scripts/devtest.py --inventory      # 三栈真实测试清点，供文档引用，替代冻结数字
python scripts/devtest.py backend-java/src/main/java/com/otaku/work/WorkSort.java
```

**改动集合怎么取**（比 acgn 更进一步）：acgn 只取 `git status`，漏掉「已提交未推送」的改动。
我们取 **`git merge-base HEAD origin/main` 到工作区的全部差异 ∪ 未跟踪文件**，
和 CI 判断「这个 PR 改了哪些文件」是同一套语义，本地与 CI 不会错位。

**三栈映射规则**

| 栈 | 触发路径 | 映射方式 | 执行命令 |
|---|---|---|---|
| Java | `backend-java/**` | 文本级三类（宁多勿少）：① 测试源码里出现该类的简单名（单词边界）；② 同包下的全部测试；③ import 了它的其它主类，再取覆盖那些类的测试（一层传播） | `./mvnw -q -B test -Dtest=A,B` |
| Python | `sync-python/**` | AST 解析测试的 `from sync.x import y` 建映射 + 测试源码文本提及 + 一层反向 | `python -m pytest tests/test_a.py -q`（cwd `sync-python`） |
| Dart | `app-client/**` | `package:otaku_app/a/b.dart` → `lib/a/b.dart`；改 lib 文件选 import 它的测试 + 一层反向；改 `test/support/*.dart` 选所有 import 它的测试 | `flutter test test/a.dart test/b.dart` |

**跨栈规则表**（这是 acgn 没有的维度，它当年只有单栈）

| 改动 | 选跑 |
|---|---|
| `docs/openapi.yaml` / `docs/data-contract.md` | 契约校验 + Java `ContractJsonShapeTest` + Python `test_importer.py`、`test_pipeline.py` + Dart `models_test.dart`、`remote_data_sources_test.dart` |
| `scripts/check-contract.py` | 跑一次契约校验 |
| `backend-java/src/main/resources/db/migration/**` | Java 全量（结构变更波及所有仓储测试），并提示 IT 类需要真库 |
| `pom.xml` / `pubspec.yaml` / `requirements.txt` | 对应栈全量（依赖变了，什么都可能变） |
| `.github/workflows/**` | 不跑，只提示「CI 配置改动，建议在 PR 里等 CI」 |
| `docs/**`（非契约）、`.workbuddy/**`、根 `*.md` | 不跑，明说「文档改动无测试覆盖要求」 |
| 拿不准的文件 | **该栈全量 + 明确警告**，绝不静默漏跑 |

**输出形态**（省 token 是硬需求）

```
== 改动 3 个文件 → 选跑 4 个测试文件 ==
  Java: WorkSortTest（覆盖 WorkSort）、WorkServiceSortAndRelatedTest（覆盖 WorkService）
  Dart: list_sort_and_related_test（import 了 work_sort.dart）
  ⚠ 有 1 个文件没有映射规则：scripts/newthing.py —— 拿不准请加 --all

$ ./mvnw -q -B test -Dtest=WorkSortTest,WorkServiceSortAndRelatedTest
  Java: 42 passed / 0 failed / 8 skipped（12.4s）
$ flutter test test/list_sort_and_related_test.dart
  Dart: 9 passed（6.1s）

结论：全部通过。可以提交。
```

失败时只打「栈 / 测试名 / 一行断言 / 文件:行」，完整堆栈留在 `--verbose-tb`。
默认不打印 traceback（要按需才给），这是 acgn `--tb=line` + 「紧凑输出省 token」的同款取舍。

**边界**：Java 的 3 个 IT 类（`ImportConcurrencyIntegrationTest` 等）靠 `IT_DB_PORT`
环境变量守门，本地不设就自动跳过——devtest 会在选到它们时明说「N 个 IT 类本地会跳过，
要真跑需起 MySQL 并设 `IT_DB_PORT=3306`」，不让人误以为跑过了。

**验收**
1. 改 `WorkSort.java` → 只选 Java 栈里提到 `WorkSort` 的测试，不选 Dart/Python；
2. 改 `docs/openapi.yaml` → 三栈各自的最少契约测试 + 契约校验，共 ≥4 个文件；
3. 改 `test/support/test_overrides.dart` → 选出所有 import 它的 Dart 测试（当前 16 个）；
4. 删掉所有改动跑 `--collect` → 明确说「没有改动」而不是空跑；
5. `--inventory` 输出的数字与实际 `grep -c` 一致。

**回滚**：删脚本，零残留（不写数据库、不改配置）。

---

### 切片 2（P0）：测试断网守卫（30 行，防事故）

在 `sync-python/tests/conftest.py` 加一个 autouse 夹具：把
`socket.socket.connect` 拦一层，除 `127.0.0.1 / ::1` 一律抛错并点名「测试不允许访问外网，
请用 stub 夹具」。同时校验 `OTAKU_BASE_URL` 之类环境变量没有指向真实站点。

现有桩服务本来就走 `127.0.0.1`，不受影响；新测试忘了 mock 会立刻失败并给出人话，
而不是安静地对真站发一次请求。

**验收**：故意写一条 `httpx.get("http://example.com")` 的测试 → 失败且报错信息指向 stub 用法；
现有 110 项全过。**回滚**：删夹具。

> 实施时改了豁免方式：原计划用 `@pytest.mark.allow_network`，实际用环境变量
> `OTAKU_TEST_ALLOW_NETWORK=1`。理由是不用注册 marker、不用改 `pytest.ini`，
> 而且它同时能表达「这一整轮允许联网」这个语义（marker 只能按用例）。
>
> 还补了一条计划里没有的：**清掉 `HTTP_PROXY` 一类环境变量**。本机代理常指向
> `127.0.0.1:port`，那种情况下 socket 的目标是代理自己——属于回环地址，
> 守卫会放行，代理再把请求转出去。第一版就是这么被绕过去的，实测才发现。

---

### 切片 3（P0）：发现性 + 文档纠偏（不写代码）

| 改动 | 位置 | 为什么 |
|---|---|---|
| 「改完跑什么」一节：先 `devtest.py`，`--all` 才全量，并链接本文 | `docs/dev-setup.md` | 人的入口 |
| 新增 15 行 `AGENTS.md`（仓库根）：三条命令 + 「不要跑全量」的替代方案 | 仓库根 | 智能体入口。**工具不写发现性，等于没做** |
| 把冻结数字改成「命令输出为准」：`mvnw test 111` 等标注「历史口径，实时数字用 `devtest.py --inventory`」 | `docs/merge-queue.md:105-107` | 缺口 4。不改历史记录本身，只给它加一句「怎么拿当前值」 |

**验收**：新人只读 `AGENTS.md` 能跑对命令；`merge-queue.md` 不再被当成实时基线。

---

### 切片 4（P1）：`scripts/smoke.py` —— 只读接口快照对比（部署后回归）

把 acgn 的 `runner` + `case_discovery` + `compare_batches` 拆成 CLI，
**去掉 Web 宿主和数据库表**，只留三件事：发请求、记形状、比上一版。

- **端点清单来源**：不硬编码（acgn 踩过硬编码模块清单漏扫描的坑，2026-10-22 实际漏了
  两个模块的路由）。我们的 `docs/openapi.yaml` 就是唯一契约，直接从里面取
  「GET 且路径无 `{}`」的端点——**零维护，且端点清单与契约天然一致**。
- **断言**：状态码落在契约声明的 2xx 内 + 契约 `required` 字段都存在 + 响应 JSON 的**键树**
  （递归取 keys，数组取首元素）与基线一致。
- **样本 id**：契约里带 `{}` 的详情类接口，先用列表端点取 `items[0]` 的 id 现场渲染，
  取不到就跳过并注明「缺样本」——这正是 acgn 方案里留下的最难那一刀（它要加数据库列，
  我们不需要）。
- **基线入库**：`scripts/smoke-baseline.json` 进仓库。接口形状变化会在 PR diff 里显形，
  评审看得见「这次改动了对外字段」，比事后抓更便宜。
- **历史**（回答 acgn 批次列表要回答的那个问题）：每次跑往 `scripts/smoke-history/` 追加一份
  完整快照，保留最近 20 份、**不入库**（`scripts/smoke-baseline.json` 才是唯一权威尺子，
  历史只是回溯用的临时轨道）。有回归时把每份历史快照也拿**同一份基线**比一遍，
  某标签第一次出现在回归集合里，就是它变坏的那次 → 输出「自 X 起，上次正常 Y（带 commit）」。
  - 为什么这么做而不学 acgn 存 `test_batches` + `test_runs` 两表：那需要数据库和新表，
    而我们只要「哪一次开始坏」这一个结论。快照是完整数据，随时可以换口径重算，
    比存下来的「当时的结论」更耐改；也不需要为它建任何表结构。
  - `baseline_id` 把关：历史只跟同一份基线比。`--save` 换了基线，旧快照自动失效、
    回溯窗口归零——否则「你刚确认的改动」会被历史当成回归，每次 `--save` 都得手工清历史。
- **退出码**：`0` 无回归 / `1` 有键消失或状态码漂移 / `2` 无法执行。

**排期**：现在可以先写脚本、对本地 `:8088` 跑；**部署后回归这一步要等 #78 服务器就位**才有真实
目标。所以列为 P1，不阻塞 P0。

---

### 切片 5（明确不做）

| 项 | 不做的理由 |
|---|---|
| 应用内 Web 测试后台 | 见第一节。没有管理页宿主，重建成本远大于收益 |
| `dev_instances.py` 文件锁 / 端口槽 / worktree | 见第一节。冲突来自 PR 分支，不来自并发写文件 |
| 静态「三端字段逐字比对」 | `scripts/check-contract.py:10-13` 已写明为什么不这么做（脆弱、假阳性多），这条决定仍然成立，不推翻 |
| GitHub Actions 加「affected」计算 | CI 已有四份 `paths` 过滤；再叠一层只是把 3 分钟的 job 变成 3 分钟 |

## 五、借鉴的开源做法

| 做法 | 出处 | 我们怎么落 |
|---|---|---|
| 「affected」：按依赖图只跑受影响的项目/目标 | Nx、Turborepo | 我们有三个独立工程，天然是三个 project。与其上构建系统，不如 350 行脚本实现同一语义 |
| 覆盖驱动的测试选择（`--lf` 同类思路） | `pytest-testmon`、`pytest --lf/--ff` | 更准，但要先跑一次全量攒覆盖数据，且跨栈不通用。**列为可选升级**（见待拍板 2） |
| 提交前钩子自动跑相关测试 | `pre-commit` | `--collect` + 钩子可以接，但会动本地 git 配置，**不在本轮** |
| 改动集合的语义 = PR diff 而非工作区状态 | GitHub Actions 的 `paths` 过滤、主流 CI | 我们用 `merge-base origin/main` 对齐 CI，本地判断和 CI 判断不会两套 |
| 输出按消费方裁剪（机器可读 + 人可读分离） | 各家 CI 的 `--format json` / JUnit XML | `--json` 一枚开关，智能体读 JSON，人读两行结论 |

## 六、验收总表

| # | 验收项 | 判定 |
|---|---|---|
| 1 | 三栈各自的选跑集合合理（改 Java 不跑 Dart、改单测试只跑它自己） | 人工过一遍 + 切片 1 的 5 条用例 |
| 2 | 拿不准的文件明确警告，绝不静默漏跑 | `--collect` 输出可见 |
| 3 | `--json` 输出可被脚本消费 | 一次解析通过 |
| 4 | 断网守卫拦得住外网、放得过 `127.0.0.1` | 故意写错一条测试验证 |
| 5 | 现有 127 / 110 / 260 项不退化 | 按 §切片 1 边界只跑相关文件；全量只在拍板后跑 |
| 6 | 文档不再被当成实时数字来源 | `merge-queue.md` 有「怎么拿当前值」 |

## 七、风险

| 编号 | 风险 | 概率 | 影响 | 应对 |
|---|---|---|---|---|
| TT-01 | Java 文本级映射漏判（反射、字符串拼类名、Spring 代理） | 中 | 中 | 只做「多选」不做「漏选」：拿不准就整栈全量；同包测试兜底（Spring 项目测试与被测类同包是惯例） |
| TT-02 | `-Dtest` 选到 0 个方法时 Maven 报错 | 中 | 低 | 加 `-DfailIfNoTests=false`；选空则该栈不执行并说明 |
| TT-03 | Dart `package:` 映射依赖包名（`otaku_app`），改名会静默失效 | 低 | 中 | 包名从 `pubspec.yaml` 读，不写死字符串 |
| TT-04 | 本地无 Flutter / JDK 时脚本行为 | 中 | 低 | 探测不到工具链 → 该栈标「跳过（未安装）」并计入结论，不算通过 |
| TT-05 | 断网守卫与将来真需要联网的测试冲突 | 低 | 低 | 提供 `@pytest.mark.allow_network` 显式豁免；默认拒 |
| TT-06 | devtest 与实际 CI 判断不一致，让人误以为「本地过了 CI 就过」 | 中 | 中 | 输出尾部固定一行：「本工具是选跑不是替代 CI；CI 会按栈跑全量」 |

## 八、已拍板

2026-10-26 确认：

1. **范围**：全做（切片 1+2+3+4），切片 5 维持不做；
2. **测试选择策略**：静态映射，不引入 `pytest-testmon`；
3. **`AGENTS.md`**：要，且作为给同事的推荐入口。

## 九、实施记录（2026-10-26）

| 交付 | 状态 | 说明 |
|---|---|---|
| `scripts/devtest.py` | ✅ | 三栈选跑；`--collect/--json/--all/--stack/--inventory/--verbose-tb`；改动基准 `merge-base HEAD origin/main` |
| `sync-python/tests/conftest.py` 断网守卫 | ✅ | autouse；拦非回环连接 + 清代理环境变量 + 拦指向真站的环境变量 |
| `AGENTS.md` | ✅ | 仓库根，命令与红线的最短入口 |
| `docs/dev-setup.md` §8 | ✅ | 「改完代码跑什么」 |
| `docs/merge-queue.md` §5 | ✅ | 验证基线标注为历史口径，给出取当前值的命令 |
| `scripts/smoke.py` | ✅ | 只读接口状态码 + 键树快照对比；端点清单取自 `docs/openapi.yaml` |
| `scripts/smoke.py --history` | ✅ | 每次跑追加快照（保留 20 份、`.gitignore` 排除）；回归时回溯「自哪一次起 / 上次正常是哪一次」；`--no-history` 可关 |
| `--json` 输出修正 | ✅ | 原先 JSON 后面还跟一行中文结论，`json.load` 直接抛 `Extra data`——机器根本读不了。现在 stdout 纯 JSON（加 `conclusion` 字段），人看的结论走 stderr |

实测记录（本机 Windows / Java 17 / Python 3.13）：

- `--inventory`：Java 19 文件 / 127 项、Python 8 文件 / 110 项、Dart 26 文件 / 260 项；
- Java 选跑实跑：改 `common/LikePattern.java` → 选 9 个测试类，56 项 7.1s，2 个 IT 类按预期跳过；
- Python 选跑实跑：改 `sync/cleaning.py` → 3 个文件 53 项 22.3s；全量 110 项 36.5s（守卫无回归）；
- Dart：**选跑映射已验证，执行链路未验证**——本机没装 Flutter（`dev-setup.md` 里那条
  `D:\dev\flutter` 是另一台机器的路径）。缺工具链时脚本会明确输出「未找到 flutter，跳过
  （不算通过）」，不会假报通过；
- `smoke.py`：用本地桩服务验证了四条路径——写基线、形状一致、字段消失（退出码 1）、
  服务不可达（退出码 2），`{work_id}` 样本 id 现场渲染可用。**真实基线尚未生成**：
  本地起后端要 MySQL，生产服务器等 #78，所以 `scripts/smoke-baseline.json` 目前不存在，
  首次对可用服务跑 `--save` 时生成（缺基线时脚本会自动写入而不是报错）。
- 历史（同一套桩服务，九条路径）：建基线即记第 1 条 → 未改判无回归 → 首次出现字段消失时
  输出「历史里首次出现」→ 再跑一次输出「自 X 起，上次正常 Y」→ `--no-history` 不落盘
  → `--json` 可被 `json.load` 解析 → 不可达时 `conclusion=unreachable` → 预置 31 份快照后
  跑一次裁到 20 份（删最旧、留最新）→ `--save` 换基线后回溯窗口归零、旧快照不再参与比对。
  **未验证**：跨真实部署的历史（要等 #78 有常开服务、间隔数小时的多次部署）。

未做（原计划就没做）：切片 5 的应用内 Web 测试后台、`dev_instances.py`、三端字段逐字比对。

---

本文为方案稿 + 实施记录，每片独立可回滚，不涉及对外契约与生产行为。

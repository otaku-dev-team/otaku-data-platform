# 测试工具第二版：从「选跑」做到「闭环」

> 前作：[`test-tooling-plan.md`](test-tooling-plan.md)（v1，已实现并提 PR #182）。
> 本文只讲 v1 之后要补什么、为什么、代价多少。属于工具层，不碰对外契约与生产行为。

---

## 一、为什么 v1 帮助有限

先给结论，再给依据。v1 的 `devtest.py` 只做了一件事：**判断该跑哪些测试文件**。它省掉的是「想清楚属于哪个栈」这几秒，而真正吃工作量和 token 的三件事它一件没碰。

| # | 缺口 | 具体表现 | 谁在承担成本 |
|---|---|---|---|
| 1 | **只回结论，不回结构** | 失败时给 8 行尾巴（`_summarize` 里的 `kept[-8:]`）。多个失败时前面的被截掉；没有测试名、没有文件行号、没有期望/实际的结构化字段。`--json` 里也没有 `failures` 数组 | 智能体必须回头读整个测试文件去找断言位置 |
| 2 | **失败后从全类重跑** | 选跑粒度是「测试文件」。改一行导致 `LikePatternTest` 里 1 个方法失败，重跑仍是整类 | 每次编辑循环多花时间，多花输出 |
| 3 | **分不清「我弄坏的」和「本来就坏的」** | 没有上次结果基线。CI 上一挂，三个人各自猜是不是自己 | 最贵的一项：整条排查路线走错 |
| 4 | **重复跑同一状态** | 改 `docs/*.md` 后仍会跑；同一份代码连跑两次仍全跑 | 时间与 token 双份 |
| 5 | **提交前要记三条命令** | 测试 / `check-contract.py` / lint 分散；CI 才发现格式问题 | 一次 CI 往返 ≈ 等 2-3 分钟 + 重读日志 |

第 1、3 条是 token 大头，不是「摘要不够短」——是**信息缺失导致智能体自己去翻文件**。

---

## 二、实测依据（本机，2026-10-26）

### 2.1 三个栈都已经产出机器可读报告，我们却在解析控制台文本

| 栈 | 现成产物 | 我们 v1 的做法 |
|---|---|---|
| Java | `backend-java/target/surefire-reports/TEST-*.xml`（实测 9 个文件 236K），含每个 `<testcase>` 的 `classname`/`name`/`time`，失败带 `<failure message=...>` 与栈帧（含 `XxxTest.java:25` 这种行号） | 正则过滤 `[ERROR]` 文本行 |
| Python | `pytest --junitxml=`（**pytest 核心，无需插件**） | 同上，过滤 `FAILED` 行 |
| Dart | `flutter test --reporter json` / `--machine` 事件流 | 同上 |

这是本次最重要的判断：**结构化信息一直都在，只是没人去读**。读报告文件而不是控制台，等于免费拿到「完整失败列表 + 精确行号 + 每个用例耗时」，且不受输出格式、`-q`、日志重定向、本地化影响。

### 2.2 「读整个测试文件」到底多贵

| 对象 | 文件数 | 平均字符 | 最大 |
|---|---|---|---|
| Java 测试 | 19 | 5,776 | 13,540 |
| Python 测试 | 8 | 6,280 | 13,271 |
| Dart 测试 | 28 | 7,568 | 15,037 |
| Java 主代码 | 77 | 2,974 | 19,246 |

一次失败迭代，智能体通常要读 1 个测试文件（≈6K 字符，约 1.5K token）+ 可能再读被测源码。而一张失败卡片（测试名 + 文件:行 + 期望/实际 + 断言前后 3 行）约 400 字符。**每次失败差一个数量级**，且省掉一次工具往返。

> 口径说明：这些是按文件实际字节数算的字符量，不是猜的。实施后 `--stats` 会输出「原始输出字节 / 卡片字节 / 读文件节省」，用真实数字替换本节的估算。

### 2.3 现状体量

`scripts/devtest.py` 805 行、`scripts/smoke.py` 483 行。再加功能会逼近 1600 行单文件，对三人团队不再可维护。

---

## 三、借鉴清单（含明确不采用的）

### 3.1 采用

| 做法 | 出处 | 我们怎么落 |
|---|---|---|
| **JUnit XML 作为统一中间格式** | pytest `--junitxml`（核心）、Maven Surefire、`dart test --reporter json` | 写一个归一化器，三端 → 同一个 `Failure` 结构。选它就是选标准：以后接任何 CI/报告工具都不用改 |
| **只重跑失败的用例** | `nextest`（retries）、`pytest --lf` | `--rerun-failed`：读上次结果 → 精确到方法重跑（surefire `-Dtest=Class#method`、pytest `file::test`、dart `--plain-name`） |
| **内容哈希缓存** | Nx / Turborepo 的 hash cache、`pytest-testmon`（覆盖哈希） | 按「入选测试文件 + 该栈主代码全量哈希 + 命令」做 key，命中直接跳过 |
| **机器可读与人可读分离** | `gotestsum` 的 `--format testname`、`nextest` | 沿用 v1 的 `--json`，补 `failures[]` 与 `schema` 版本号 |
| **单命令门禁** | `pre-commit` | `--gate`：选跑 + 契约校验 + 可选 lint，统一退出码，一次工具调用 |
| **毫秒级 lint** | `astral-sh/ruff` | 见 5.2，需同意后接 |

**没有可以整段搬的代码**，这点直说：`gotestsum` 是 Go 的、`nextest` 是 Rust 的、`testmon` 的覆盖驱动和我们「保守优先」的取向不一致。值得搬的是**格式约定与语义**（JUnit XML、`--rerun-failed` 的行为），不是源文件。

### 3.2 评估过但不采用

| 项 | 出处 | 不采用的原因 |
|---|---|---|
| **STARTS / Ekstazi 静态 RTS（Java 类级测试选择）** | `TestingResearchIllinois/starts` | ① 要求改 `pom.xml`，给 surefire 配 `excludesFile`，官方 FAQ 自己承认这样会**破坏普通 `mvn test`**；② 官方只验证到 Java 15，我们 17 + Spring Boot 3.5；③ 静态分析在 Spring DI / 反射下有盲区，漏选就是假绿——比多跑几个测试危险得多。收益（省几个测试类）远小于「静默漏跑」的风险 |
| `pytest-testmon` 覆盖驱动选跑 | `tarpas/pytest-testmon` | 只覆盖 Python 一栈，另两栈仍要静态映射；首次必须全量攒数据；且覆盖驱动会「因为没覆盖到所以不选」，与我们「拿不准就整栈全量」的原则相反 |
| Nx / Bazel / Turborepo | — | 三个独立工程已天然分栈，上一套构建系统只为测试选择，成本远超收益 |
| 自建 Web 面板 | acgn 的 `testing_pages` | v1 已论证过：宿主不匹配 |

---

## 四、方案切片

### P0 —— 闭环的核心（四件，缺一件效果都不完整）

**S1 统一失败模型 + 失败卡片**

- `scripts/devkit/report.py`：三端报告 → `dataclass Failure(test, file, line, message, stack, duration)`。
  - Java：读 `target/surefire-reports/TEST-*.xml`，跳过庞大的 `<properties>`（236K 里绝大部分是它）。
  - Python：跑 pytest 时加 `--junitxml=<临时>`。
  - Dart：`--reporter json` 事件流。
- 卡片渲染（示意，结构取自真实文件）：

```
✗ Java  LikePatternTest#escapesWildcards
  backend-java/src/test/java/com/otaku/common/LikePatternTest.java:19
  expected: "%50!%%"  but was: "%50%%"
     17 |     @DisplayName("用户输入的 % 和 _ 当普通字符，不能变成通配符")
     18 |     void escapesWildcards() {
  >  19 |         assertThat(LikePattern.contains("50%")).isEqualTo("%50!%%");
     20 |         assertThat(LikePattern.contains("a_b")).isEqualTo("%a!_b%")
  └─ 被测 LikePattern.contains()
```

- **省什么**：省掉「为了找断言在哪而读整个测试文件」。卡片自带行号与上下文，智能体可以直接动手改。
- **风险**：三个格式的兼容性；Java XML 若无更新（Maven 跳过测试）要能识别为「无报告」而不是「0 失败」——加报告时间戳与运行开始时间比对。

**S2 `--rerun-failed`：精确到方法重跑**

- 读上次结果 → 拼精确命令。Java `-Dtest=LikePatternTest#escapesWildcards`；pytest `tests/test_x.py::test_foo`；dart `--plain-name "..."`（不支持多选时逐个跑）。
- **省什么**：编辑循环从「整类重跑」变成「只跑这一个方法」，通常 <2s。这是人最能直接感觉到的提速。
- **风险**：`--plain-name` 是字符串匹配，重名会多跑（可接受，宁多不漏）。

**S3 结果缓存**

- key = `sha256(命令 + 入选测试文件内容 + 该栈主代码全量哈希 + 依赖清单哈希 + 工具链版本)`。
- 命中输出一行：`Java: 跳过（同一状态上次通过 02:41，9/9）`，**必须显式标 cached**，不能伪装成跑过。
- 为什么用「整栈主代码全量哈希」而不是依赖闭包：我们规模小（Java 77 文件 229K，哈希约 10ms），闭包一旦不准就是**误跳过 = 假绿**。宁可多失效一次，不冒这个险。要更激进可以后续加 `--fast-cache`。
- **省什么**：改文档、改别的栈、只是确认一下，这类「其实没改到这一栈」的场景直接秒过。

**S4 失败基线：新失败 vs 既有失败**

- 记录上次的失败集合；本次失败逐个标注 `新增` / `上次也失败（已持续 3 次）` / `已修复`。
- 再进一步：失败用例的依赖闭包**不包含**本次改动的文件时，直接标 `与本次改动无关`。
- **省什么**：这一条省的是最贵的部分——整条排查路线走错。CI 上一挂，先看一眼就知道该不该动。
- **风险**：依赖闭包不准会误标「无关」。措辞必须是「疑似与本次改动无关」，不能当结论。

### P1 —— 门禁与提速

**S5 `--gate`：一条命令等价于 CI**

- 内容 = 选跑 + 契约校验（`check-contract.py`，仅当契约文件动过）+ 可选 lint。
- 定义来源有两种，需选：手写映射（简单、会过期）／解析 `.github/workflows/*.yml` 的 `paths` 与 `run:` 自动生成（CI 改了自动跟上，但依赖 workflow 结构稳定，解析失败要回退默认）。**我倾向前者**，理由见 §7。
- 一处通过 = CI 基本会过，省一次往返。

**S6 flaky 与慢用例**

- `--retry 1`：只复跑失败用例，复跑通过则标「疑似不稳定」，退出码仍为失败（不静默）。
- `--slow 5`：从报告里的 `time` 直接出最慢 5 个（数据免费，代码不到 20 行）。

**S7 多栈并行**

- 三栈现在是顺序跑。改 `--gate` 时并行执行，墙钟时间从「求和」变「取最大」。
- 风险：输出交错。有了卡片渲染不构成问题。

### P2 —— 可选，看你要不要

| 项 | 价值 | 代价 / 风险 |
|---|---|---|
| ruff 接入（Python lint + `--fix`） | 毫秒级抓到 CI 会拦的问题；目前**三栈零 lint** | 要加依赖与配置；**是否进 CI 属于团队规则变更，需三人同意**，不能我们单方面定 |
| `--watch` | 人改代码即时看到结果 | 对智能体无价值（它本来就批处理），人用得多才值得 |
| repo map / 符号索引（aider 风格） | 减少「找不到东西」的探索 token | 与测试工具不是一件事，另一条线，单独评估 |

---

## 五、目标输出长什么样

### 现在（失败时）

```
  Java: 9 个文件
    ...（省略）
✓ Java 9/9 通过 7.1s
```
失败时给出 8 行尾巴，没有结构。智能体接下来会 `Read` 整个测试文件。

### 之后

```
Java   9 个文件  56 项  2.1s  ← 缓存命中（同一状态上次通过 02:41）
Python 3 个文件  53 项  22.3s

✗ Python  test_importer.py::test_rating_out_of_range
  sync-python/tests/test_importer.py:88
  assert item.status == "rejected"  ->  got "accepted"
     86 |     item = build(release_year=2101)
     87 |     result = importer.apply(item)
  >  88 |     assert result.status == "rejected"
  └─ 新增失败（上次通过）· 与本次改动相关：同步接口
结论：1 项失败，1 项已修复。
```

同样的信息量，字符数从「6K 文件 + 8 行日志」降到约 400。

---

## 六、成本与顺序

| 切片 | 新增/改动 | 风险 | 依赖 |
|---|---|---|---|
| S1 报告归一 + 卡片 | 新 `scripts/devkit/report.py` 约 300 行；`devtest.py` 改输出层 | 中（三格式） | 无 |
| S2 `--rerun-failed` | 约 80 行 | 低 | S1 |
| S3 缓存 | 约 100 行 | 中（假绿风险，用保守 key 规避） | S1 |
| S4 失败基线 | 约 120 行 | 中（措辞必须留余地） | S1 |
| S5 `--gate` | 约 100 行 | 低 | S1 |
| S6 `--retry` / `--slow` | 约 60 行 | 低 | S1 |
| S7 并行 | 约 40 行 | 低 | — |
| ruff | 配置 + CI 决策 | 规则变更需同意 | — |

**架构**：新代码集中在 `scripts/devkit/`（只加不改），`scripts/devtest.py` 保留现有选跑逻辑当入口。理由：选跑逻辑已经对了、在跑、有人用（v1 已提 PR），重写它是纯浪费；而新增的报告/卡片/缓存是另一类复杂度，混进 805 行单文件会让两边都难改。

**Dart 的现实约束**：本机没有 Flutter（`dev-setup.md` 里 `D:\dev\flutter` 是另一台机器的路径）。S1 的 Dart 部分可以写，但**执行链路在这里验不了**，只能等装了 Flutter 的机器跑一次。方案里凡是涉及 Dart 的都会标「未验证」，不假装跑过。

---

## 七、不做什么

| 项 | 理由 |
|---|---|
| 重写现有选跑逻辑 | 它是对的、在用。收益为零，风险非零 |
| 覆盖率驱动选跑（三栈统一） | 只有 Python 有现成方案；且与「拿不准就整栈全量」的原则冲突 |
| 静态 RTS（STARTS/Ekstazi） | 见 §3.2，破坏 `mvn test` + Java 版本不匹配 + 假绿风险 |
| 自动解析 CI workflow 生成 gate | 方向正确但脆：workflow 结构一改解析就错，而错的表现是「gate 漏了某项」——正是我们要防的。硬编码映射更土但坏了看得见 |
| 自建面板 / 历史看板 | v1 已论证；`smoke.py --history` 已覆盖「从哪次开始坏」 |
| 覆盖率报告、flaky 平台 | 三人团队，没人每天看 |

---

## 八、需要拍板

1. **范围**：只做 P0（S1-S4）／P0+P1（再加门禁、flaky、并行）／全做（含 ruff 与 watch）？
2. **缓存的默认行为**：默认开（命中即跳过，可能因 key 不准而多失效）／默认关、`--cache` 显式开？
3. **ruff 要不要接，接了要不要进 CI**：这是给三个人加规则，我只做本地可选、不擅自改 CI。
4. **`--gate` 的内容来源**：手写映射（坏了看得见）／解析 workflow（自动跟 CI 走，但脆）？

---

本文为方案稿，未写任何实现代码。确认后按切片实施，每片独立可回滚。

---

## 九、实施记录（2026-10-26）

按 P0 + P1 落地，UI 并入。代码在 `devkit/`（仓库根），`scripts/devtest.py` 变成转发壳，
既有命令与文档全部不用改。

| 项 | 状态 | 说明 |
|---|---|---|
| S1 报告归一 + 卡片 | 完成 | `devkit/report.py` 三个解析器 + `card.py`；Java/Python 实跑验证，Dart 未验证 |
| S2 `--rerun-failed` | 完成 | Java `-Dtest=Class#method`、pytest `file::test`、dart `--plain-name` |
| S3 缓存 | 完成 | 保守键：命令 + 入选文件 + 该栈全目录哈希；命中显式标「缓存命中」 |
| S4 失败基线 | 完成 | `last.json` 记失败集合，卡片标「新增失败 / 上次也失败」 |
| S5 `--gate` | 完成 | 选跑 + `check-contract.py`，退出码合并 |
| S6 `--retry` / `--slow` | 完成 | flaky 标记来自 `--retry`；慢用例取报告里的 time |
| S7 三栈并行 | 完成 | 线程池，单栈异常不影响另外两个 |
| UI 本地看板 | 完成 | `python -m devkit serve --port 8787`，标准库 http.server + 原生 HTML/JS |

### 实施中发现并修掉的六个真问题

1. **`--tb=line` 会把 junitxml 里的 traceback 一起压掉**，报告里只剩断言消息、没有「文件:行」，
   卡片就等于白做。改成：传了 `--junitxml` 就不再传 `--tb`。
2. **缓存永不命中**：`--junitxml` 带随机文件名，等于每次命令都不同。把该参数抹成占位符再哈希。
3. **surefire 旧报告会被当成本次结果**：`-Dtest=X` 只重写 X 的 XML，其余旧文件仍在。
   按 mtime ≥ 运行开始时间过滤——这是最容易踩的假绿。
4. **`mvnw.cmd` 依赖系统脚本宿主**：环境里没有时只会吐「Cannot start maven from wrapper」，
   被误当成「0 条失败线索」。改为探测到缺失时走 `mvnw` 这个 shell 脚本。
5. **JAVA_HOME 未配时静默通过**：原来输出「0 条失败线索」且结论「全部通过」。
   现在明说「JAVA_HOME 未设置且 PATH 里没有 java」，且一个栈都没跑成时退出码为 2。
6. **`--json` 后面跟一行中文结论**（v1 遗留）导致 `json.load` 抛 `Extra data`。已修为纯 JSON。

### 验证过 / 没验证

- 已跑通：Python 失败卡片（文件:行 + 前后 3 行 + 新增/上次也失败）、`--rerun-failed` 只跑 1 项、
  缓存二次命中、`--retry` 识别 flaky、`--gate` 契约校验、`--json` 可解析、Java 选跑 3 项 5.1s
  （surefire 解析与卡片渲染用真实报告验过）、看板 `/api/state` 与 `/api/run` 全链路。
- **未验证**：Dart 执行链路（本机没 Flutter）；Java 的失败卡片是构造 surefire XML 验的解析路径，
  没有真把测试改坏去跑（避免污染仓库）。
- 本机 `JAVA_HOME` 为空、PATH 里没有 `java`（JDK 在 `C:\Users\52487\.jdks\`），
  Java 相关实跑需临时加 `JAVA_HOME=...` 前缀。

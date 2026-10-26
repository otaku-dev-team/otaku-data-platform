# devkit

本仓库的测试工具：**按改动选跑 → 结构化失败 → 与上次对比 → 门禁 → 本地看板**。

放在仓库根目录而不是 `scripts/`：`scripts/` 是共用的一次性运维脚本堆，这个工具会长，
将来可能拆出去单独维护。入口仍是 `python scripts/devtest.py`（转发壳），用法不变。

## 命令

```bash
python scripts/devtest.py                  # 自动看改动 → 选跑 → 只回结论
python scripts/devtest.py --collect        # 只看选跑计划，不执行
python scripts/devtest.py --gate           # 跑测试 + 契约校验（≈ 本地过一遍 CI）
python scripts/devtest.py --rerun-failed   # 只重跑上次失败的用例（精确到方法）
python scripts/devtest.py --retry 1        # 失败用例复跑一次，复跑通过则标「疑似不稳定」
python scripts/devtest.py --slow 5         # 顺便列最慢的 5 个用例
python scripts/devtest.py --json           # 机器可读（stdout 只有 JSON）
python scripts/devtest.py --inventory      # 三栈测试实时清点
python scripts/devtest.py --stats          # 原始输出 vs 卡片的字节数对比
python -m devkit serve --port 8787         # 本地看板
```

退出码：`0` 通过 ／ `1` 有失败或疑似不稳定 ／ `2` 无法执行（工具链缺失、什么都没跑成）。

## 长什么样

```
Java   跳过（不算通过）：JAVA_HOME 未设置且 PATH 里没有 java（mvnw 需要其中之一）
Python 2 项  1 失败  1.1s

[FAIL] tests/test_importer.py::test_release_year_out_of_range
    sync-python/tests/test_importer.py:88
    AssertionError: 越界应整条 rejected
       86 |     item = build(release_year=2101)
       87 |     result = importer.apply(item)
     > 88 |     assert result.status == "rejected"
       新增失败

结论：1 项失败（1 项新增）。
```

## 为什么这样设计

**读报告文件，不读控制台。** 三个栈本来就在磁盘上产出机器可读报告：Java 是 surefire 默认
就写的 `target/surefire-reports/TEST-*.xml`，pytest 加 `--junitxml` 即可（核心功能，不用装
插件），Dart 用 `--reporter json`。比正则过滤控制台强在：失败列表完整（不被尾巴截断）、
带精确到文件行号、带每个用例耗时，且不受 `-q`/日志重定向/系统语言影响。

**卡片自带上下文。** 一次失败迭代，读者原本要打开测试文件找断言（Java 测试平均 5.8K 字符），
现在卡片里就有行号和前后各 3 行。省的是 token 与一次工具往返。

**缓存保守优先。** 缓存键 = 命令 + 入选测试文件 + **该栈目录全部被跟踪文件的哈希**。
不用依赖闭包，因为闭包漏一个文件就是「跳过了一次本该失败的运行」= 假绿；
两者代价不对称。想把键放松成闭包哈希，得先证明闭包是准的。

**失败基线。** 记住上次失败集合，本次逐条标「新增失败 / 上次也失败」。
没有它，CI 上一挂，所有人都得先自己猜是不是自己弄坏的。

**跳过 ≠ 通过。** 工具链缺失、JAVA_HOME 没配、什么都没跑成，一律显式说明并让退出码
变成 `2`，绝不在结论里写「全部通过」。

## 目录

| 文件 | 职责 |
| --- | --- |
| `select.py` | 改动 → 该跑哪些文件（三栈静态映射；拿不准就整栈全量） |
| `report.py` | 三栈报告 → 统一的 `StackReport` / `Case` / `Failure` |
| `card.py` | 失败卡片渲染（终端用 ASCII 记号，GBK 控制台不会崩） |
| `run.py` | 执行、并行、复跑、缓存读写、状态组装 |
| `cache.py` / `state.py` | 结果缓存；上次结果、失败基线、运行历史 |
| `cli.py` | 参数与输出（终端 / JSON 两套） |
| `server.py` + `ui/` | 本地看板：只读 `/api/state`，预设动作 `/api/run` |

运行数据在 `devkit/.state/`（缓存、`last.json`、`runs/`），**已 gitignore**，不入库。

## 看板

```bash
python -m devkit serve --port 8787     # http://127.0.0.1:8787
```

只绑回环地址，只接受四个预设动作（选跑 / 门禁 / 重跑失败 / 全量），**不接受任意命令**——
它会在你机器上起子进程，不能做成通用的远程执行。

## 接新的栈或新的项目

- 新栈：在 `select.py` 加选择器、在 `run.py` 的 `STACK_DIR` 登记目录、在 `report.py` 加
  一个解析器（若该栈能出 JUnit XML，直接复用 `parse_junit_xml`）。
- 换项目：`select.py` 顶部的路径常量是唯一与仓库强绑定的地方，搬走时改那一段。

## 已知限制

- **Dart 执行链路未在本机验证**（没装 Flutter）。选跑与解析代码已写，缺工具链时会明确
  跳过并让退出码变 2，不会假报通过。
- Java 在 Windows 上若 `mvnw.cmd` 依赖的 shells 不在 PATH，会自动改走 `mvnw` 脚本；
  两者都不行时提示「JAVA_HOME 未设置且 PATH 里没有 java」。
- `--retry` 只复跑失败用例，不重跑整个类。

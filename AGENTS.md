# AGENTS.md

给在这个仓库里干活的智能体（和懒得记命令的人）。三分钟看完，省下每次重新推断的时间。

## 改完代码先跑这一条

```bash
python scripts/devtest.py
```

它会自己看「这轮改了什么」，判断属于 Java / Python / Dart 哪几个栈、该跑哪些测试文件，
然后跑掉，只回结论。**不要上来就三栈全量。**

```bash
python scripts/devtest.py --collect   # 只列清单和原因，不动手（先看规划时用）
python scripts/devtest.py --json      # 机器可读，适合脚本/智能体接手
python scripts/devtest.py --all       # 明确全量，慎用
python scripts/devtest.py --inventory # 三栈测试实时清点（文档里的数字会过期，这个不会）
python scripts/devtest.py --gate      # 测试 + 契约校验，≈ 本地过一遍 CI
python scripts/devtest.py --rerun-failed  # 只重跑上次失败的用例（精确到方法，通常 <2s）
python -m devkit serve --port 8787    # 本地看板（失败卡片、慢用例、历史）
```

失败时会直接给**卡片**：测试名 + 文件:行 + 断言消息 + 前后各 3 行源码，
并标注「新增失败 / 上次也失败」。**不要为了找断言位置去读整个测试文件**，卡片里已经有了。
实现与设计取舍见 `devkit/README.md`；`scripts/devtest.py` 只是转发壳。

读输出只要看结论那行：`结论：全部通过。可以提交。` 或哪一栈失败、哪几项是新增失败。
**「跳过」不等于「通过」**（工具链缺失时会明说并让退出码变 2）。

## 三栈各自的原始命令（devtest 内部用的就是这些）

| 栈 | 目录 | 命令 | 备注 |
| --- | --- | --- | --- |
| Java | `backend-java/` | `./mvnw -B test` | 3 个集成测试类要真 MySQL，无 `IT_DB_PORT` 时整类跳过 |
| Python | `sync-python/` | `python -m pytest -q` | 测试全走本地桩服务，**禁止连真站**（conftest 有硬拦截） |
| Dart | `app-client/` | `flutter test` | 另有 `flutter analyze`；CI 还会跑一次 `flutter build apk --debug` |

CI（`.github/workflows/`）按栈跑全量。**本地选跑过了不等于 CI 会过**，别把 devtest 当 CI 用。

## 部署后回归

```bash
python scripts/smoke.py --base-url <地址> --save   # 首次/确认改动后更新基线（入库，PR 里能看见对外字段变化）
python scripts/smoke.py --base-url <地址>          # 对比，退出码 0 无回归 / 1 有回归 / 2 无法执行
```

只发 GET。有回归时会回溯 `scripts/smoke-history/`（每次跑自动留一条，20 份上限、不入库），
直接给出「自哪一次起、上次正常是哪一次」。`--json` 的 stdout 是纯 JSON，可直接喂给脚本。

## 提交前的硬约束

- 跨模块接口 / 数据结构 / 铁律边界 / 密钥 / 生产数据承诺 → 需三人确认，走 PR（红线清单见 `docs/project-charter.md` §3.2）；
- 契约只改 `docs/openapi.yaml` 一处，三端各自跟随；改完跑 `python scripts/check-contract.py`；
- 密钥只进环境变量，绝不入库；
- 不代合并别人的 PR；「确认」是知悉不是审批。

## 找东西

| 想知道 | 看 |
| --- | --- |
| 项目定位与边界（改技术方案前必读） | `docs/product-positioning.md` |
| 数据契约、字段口径 | `docs/data-contract.md`、`docs/openapi.yaml` |
| 部署 | `docs/deploy-production.md` |
| 合并进度与开放 PR | `docs/merge-queue.md` |
| 待决事项 | `docs/open-decisions.md` |
| 测试工具为什么长这样 | `docs/test-tooling-plan.md` |

还没定的商务细节一律 `[待定]`，不要编数字。

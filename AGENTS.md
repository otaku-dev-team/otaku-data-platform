# AGENTS.md

给在这个仓库里干活的智能体（和懒得记命令的人）。三分钟看完，省下每次重新推断的时间。

## 改完代码先跑这一条

```bash
python scripts/devtest.py
```

它会自己看「这轮改了什么」，判断属于 Java / Python / Dart 哪几个栈、该跑哪些测试文件，
然后跑掉，只回结论。**不要上来就三栈全量。**

一次典型改动十几秒到一分钟，输出只有几行（结论 + 失败卡片），同一份代码第二次跑直接命中缓存。
**所以「先跑一下」一般比「猜有没有改坏」便宜。** 改动落在 devkit 自己身上时会多出一栈
「工具」，跑它的测试（23 项、两秒多）——工具以前验证不了自己，这一栈就是补那个洞。

有两类它故意不管，跑完请自己补一次，别当成验收过了：`scripts/` 下的脚本，以及配置/部署文件
（`application.yml`、`compose*.yaml`、`.env*`、CI 工作流）。后者的验证动作在部署之后，
走下面的 `smoke.py`。

```bash
python scripts/devtest.py --collect   # 只列清单和原因，不动手（先看规划时用）
python scripts/devtest.py --json      # 机器可读，适合脚本/智能体接手
python scripts/devtest.py --all       # 明确全量，慎用
python scripts/devtest.py --inventory # 三栈测试实时清点（文档里的数字会过期，这个不会）
python scripts/devtest.py --gate      # 测试 + 本机可跑的 CI 守卫（契约、站点隔离）
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

## 推送总掉线（502 / CONNECT tunnel failed / schannel 中断）

本机带全局 `HTTP_PROXY` 时，HTTPS 远端的推送（smart-HTTP 长上传）会被代理间歇 502 掐断，
而 `api.github.com` 一直正常——所以 `gh pr` / `gh api` 能用、`git push` 老失败，不是权限问题，是传输通道问题。

**根治：远端改走 SSH**（SSH 不经过 HTTP 代理，实测稳定；改完推送不再需要重试或退化到 API 兜底）。

```bash
ssh-keygen -t ed25519 -N "" -f ~/.ssh/github_otaku          # 本地专用钥，别复用部署钥
gh api user/keys --method POST --input - <<<"{\"title\":\"$(hostname)\",\"key\":\"$(cat ~/.ssh/github_otaku.pub)\"}"
git remote set-url origin git@github.com:otaku-dev-team/otaku-data-platform.git
```

- `~/.ssh/config` 里给 `Host github.com` 固定 `IdentityFile` + `ProxyCommand none`，避免被代理劫持；
- 22 端口被墙时改走 `ssh.github.com:443`（同文件加一段 `Host ssh.github.com` / `Port 443`，远端换成该 Host）；
- **本仓库禁用了 deploy key**（`POST /repos/:owner/:repo/keys` 会 422），只能用账号级 SSH key；
- 只想临时确认哪条通道通：`curl -s -o /dev/null -w '%{http_code}' https://api.github.com/` 正常而
  `https://github.com/` 超时，就走 SSH。

## 找东西

| 想知道 | 看 |
| --- | --- |
| 项目定位与边界（改技术方案前必读） | `docs/product-positioning.md` |
| 数据契约、字段口径 | `docs/data-contract.md`、`docs/openapi.yaml` |
| 部署 | `docs/deploy-production.md` |
| 「有多少人在用」/ 使用统计口径 | `docs/usage-analytics.md`（日志统计脚本 `scripts/usage.py`） |
| 合并进度与开放 PR | `docs/merge-queue.md` |
| 待决事项 | `docs/open-decisions.md` |
| 测试工具为什么长这样 | `docs/test-tooling-plan.md` |
| 并行开发 · 阻塞处理（不停车） | `docs/collaboration-protocol.md` |
| 客户端联调现状（导入期间能否开发） | `docs/client-dev-handoff.md` |
还没定的商务细节一律 `[待定]`，不要编数字。

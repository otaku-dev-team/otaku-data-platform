# 任务看板 · ROADMAP

> 负责人任务协调文档 · 2026-10-20 · 负责人：zm
>
> **性质说明**：本文是负责人的协调看板，**只定目标/产出与验收口径，不规定技术选型、实现顺序与内部重构**。契约仍以 [`openapi.yaml`](openapi.yaml) 与 [`data-contract.md`](data-contract.md) 为准；跨模块接口/数据结构变更须经三人确认后方生效。
> 详细产品范围与架构见 [`otaku-project-plan-v2.md`](otaku-project-plan-v2.md)，第一阶段契约见 [`stage1-minimal-contract.md`](stage1-minimal-contract.md)。

## 1. 现状快照（2026-10-21）

| 模块 | 负责人 | 状态 |
|---|---|---|
| backend-java | @pyxz0 | 第一阶段完工；bangumi 4 个兼容点已实测落地；`(source, source_id)` 唯一键生效。待：全量吞吐验证、生产化、阶段 2 契约确认（3/4/8 项） |
| app-client | @riceyu02 | 阶段 1 联调已合并（PR #26–#30）；**阶段 2 骨架已合并（PR #33：登录/收藏/令牌存储/401 兜底）**；契约草案已提（Issue #32 / PR #31），待三人确认 |
| sync-python | @zhengmin486 | 完结：适配器 + 流式分批 + 均匀抽样 + CLI 兜底（PR #24 已合并）；55 项测试 + CI 绿；1 万均匀样本在库；全量推送定案不推（走档案分发） |

> 仓库已迁至组织 **[otaku-dev-team/otaku-data-platform](https://github.com/otaku-dev-team/otaku-data-platform)**；
> 三人均为 admin。档案分发：draft release `data-bangumi-2026-10-21`（268MB 瘦身档，详见 [`bangumi-archive-handover.md`](bangumi-archive-handover.md)）。

## 2. 任务分配（只定目标）

### 2.1 后端 @pyxz0
- **T1 全量导入稳定性**：等 sync-python 推全量（约 55.6 万）时，确认分批导入不丢批、不超时、错误可见。
  - 验收口径：导入过程零 `rejected`、批次进度可观测、失败可重试。
- **T2 客户端联调支撑**：app-client 切真实接口后，配合定位字段 / 分页 / 鉴权问题。
  - 约束：以 `openapi.yaml` 为唯一契约，**不临时改字段**。
- **T3 生产化（自主排期）**：部署方式、DB 迁移、鉴权 / 限流、健康检查与告警——方案自定，负责人只看里程碑节点。
- 🔓 自由度：技术选型、实现顺序、内部重构不干预；仅跨模块接口变更需同步三人确认。

### 2.2 客户端 Flutter 负责人
- **T1 跑通真实接口**：本地起后端后，关闭 Mock 开关，联调列表 / 详情两页；记录并反馈任何契约偏差。
- **T2 数据呈现打磨**：封面占位（bangumi 暂无封面）、评分 / 标签展示——按产品判断，**不定 UI 细节**。
- 🔓 自由度：架构、状态管理、页面细节自行决定；只要求"能联调、能反馈契约问题"。

### 2.3 sync-python（zm）
- [x] **T1 全量推送决策**：已定——**不推**。理由：本机推全量只充实本机库（C 盘余量仅 3.2GB，MySQL 在 C 盘），
      同事环境仍为空；改为档案分发，各自导入。能力已就绪，将来共享服务器上一条命令即可执行。
- **T2 封面补全（可选）**：bangumi 档案无封面字段，`cover_url` 全 `null`——是否补封面抓取待与产品 / 后端确认，**不擅自加外部抓取负担**。
- [x] **T3 收尾 PR**：PR #24 已合并进 main（`7316138`），分支已删。

## 3. 负责人边界（不越位）
- **唯一强约束**：跨模块接口 / 数据结构变更 → 三人确认 → 落 docs/ 契约生效。
- **不过问**：代码细节、实现顺序、技术栈选择。
- **只盯**：里程碑节点 + 契约一致性；进度按需同步，不日常盯。

## 4. 进度更新（2026-10-21）

### 4.1 复核结果（实测，非推测）
- 本机后端健康检查 `GET /actuator/health` → **200**；MySQL 3306 在监听；档案（445MB）在位。
- 库内 `work` 表：`source=bangumi` **10,001 条**（含 1 条 smoke），类型分布 anime 543 / comic 5746 / game 2075 / novel 1637。
- sync-python 测试 **55 项全部通过**（原 50 + 新增 5）。
- 真实档案全量统计复核：anime 31174 / comic 320631 / game 117295 / novel 87116，合计 **556,216**，与文档一致。
- 数据缺口复核：`infobox` 为模板字符串，能补出中文名的比例仅 **0.02%**——标题/封面/评分的缺失是档案本身的硬限制，不再作为代码问题处理。

### 4.2 本轮已解决（sync-python 自身问题）
| 问题 | 影响 | 处理 |
|---|---|---|
| `--sample uniform` 缺 `--limit` 时静默退化为按 id 顺序取 | 以为抽了样，实际样本有偏 | 改为直接报错退出（exit 2） |
| `--sample` 默认值恒为 `head`，覆盖 `OTAKU_SAMPLE_METHOD` | README 记录的该环境变量实际失效 | 默认改 `None`，环境变量恢复生效 |
| `--source bangumi` 缺档案路径 / 环境变量拼错 | 抛裸 traceback 或静默走去联网 | 统一友好报错（exit 2） |
| 长任务无进度、被中断不落报告 | 全量上千批时无法判断是否卡死，中断即丢记录 | 每 50 批打进度 + Ctrl-C 先落盘运行报告 |

### 4.3 M2 全量数据落地（已定案：不推）
- ~~目标：把可用数据从 1.8% 推进到全量 55.6 万~~ → **决策（2026-10-21）：不在本机推全量**。
- **理由**：本机推全量只充实本机库，同事环境仍为空；且 C 盘仅剩 3.2GB、MySQL datadir 在 C 盘，有磁盘风险。
- **定案方式**：档案分发（draft release），协作者各自导入到本地后端；将来后端部署到共享服务器时，用同一命令执行全量即可。
- 验收口径保留备查：入库 `rejected=0`、总数与档案匹配（55.6 万 + smoke）、中断可幂等重跑。

## 5. 下一步（待决策 / 待办）
- [x] **仓库迁入组织** `otaku-dev-team`：三人（@zhengmin486 / @riceyu02 / @pyxz0）均为 admin；
      组织默认仓库权限已设为 admin；PR、draft release、协作者均随仓库迁移。
- [x] **B. 分发档案**：瘦身档 268MB 已上传为 draft release `data-bangumi-2026-10-21`
      （详见 [`bangumi-archive-handover.md`](bangumi-archive-handover.md)）。协作者接受组织邀请后可下载。
- [x] **A. 本机推全量**：已决策**不推**（理由见 4.3）。能力与命令已备于交接文档，待共享服务器就位再执行。
- [x] **CI**：新增 `.github/workflows/sync-python.yml`（checkout@v7 / setup-python@v7），
      PR #24 上实测 24 秒通过，后续 Python 改动自动跑 55 项测试。
- [x] **评审 PR #26**（客户端 Windows + Android 真接口联调）——已合并进 main。
- [x] **合并 PR #24**：已合并（merge commit `7316138`），main CI 绿，分支已清理。
- [x] **阶段 2 契约评审（负责人）**：已在 Issue #32 回复——三个决策（平台自建账号 / 不透明令牌 / LWW）全部采纳，
      确认三人项 1/2/7；补数据侧意见（`work_id` 示例风格统一、联调不依赖全量、双向隔离成立）。
- [ ] **阶段 2 契约确认收尾**（@pyxz0 确认 3/4/8 → Java + Flutter 确认 5/6）：
      - [ ] @pyxz0 把接口写进 `openapi.yaml`（草案 `docs/stage2-account-collection-contract.md` 留作设计理由）
      - [ ] @riceyu02 提 PR 改 `flutter-lead-plan.md` §8 第 1 条验收表述
      - [ ] 三人确认齐后，提 PR 改 `stage1-minimal-contract.md` 铁律 2 原文
      - [ ] 全部落地后回 Issue #32 标记完成
- [ ] **阶段 2 联调**：A/B 账号（附录 A 内部接口或 SQL 建号）+ 现有 10,001 条数据即可覆盖 C1–C11，不依赖全量导入。

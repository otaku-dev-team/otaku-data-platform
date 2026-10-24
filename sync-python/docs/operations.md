# sync-python 运营手册

> 适用：负责 `sync-python` 的运维 / 联调 / 定时化。本文是操作指引，**不涉及代码改动**。
> 关联：[`stage1-minimal-contract.md`](../../docs/stage1-minimal-contract.md)、[`data-completeness-plan.md`](../../docs/data-completeness-plan.md)、[`generalization-proposal.md`](../../docs/generalization-proposal.md)
> 作者：zm ｜ 日期：2026-10-23

---

## 1. 本地灌库操作指引（对应 Issue #61）

### 1.1 前置准备

- Python 3.11+，安装依赖（见 `sync-python` 的 `requirements.txt` / `pyproject.toml`）。
- **敏感值只从环境变量读取，不写入仓库**（见 `config.py`）。常用变量：
  - `OTAKU_INTERNAL_TOKEN`：Java 后端导入令牌（**正式提交必需**；`--dry-run` 不需要）。
  - `OTAKU_SOURCE_BASE_URL`：来源站地址（默认 `http://154.8.194.198:8000`）。
  - `OTAKU_JAVA_BASE_URL`：后端地址（默认 `http://localhost:8080`）。
  - `OTAKU_ARCHIVE_PATH`：Bangumi 档案 `dump.zip` 路径（`--source bangumi` 必需）。
  - `OTAKU_SOURCE`：`otaku_site`（默认）或 `bangumi`。
  - `OTAKU_WORK_TYPES`：逗号分隔，默认 `anime,comic,game,novel`。
  - `OTAKU_BATCH_SIZE`：每批条数，默认 100（**上限 500**，超限直接报错退出）。
  - `OTAKU_SAMPLE_METHOD`：`head`（按档案顺序取前 N 条）或 `uniform`（蓄水池随机抽样）。
  - 其余限流参数（`OTAKU_SOURCE_PAGE_SIZE` / `OTAKU_REQUEST_INTERVAL_SECONDS` / `OTAKU_MAX_PAGES` / `OTAKU_TIMEOUT_SECONDS` / `OTAKU_MAX_ATTEMPTS` / `OTAKU_BACKOFF_SECONDS` / `OTAKU_OUTPUT_DIR`）均可环境变量覆盖，详见 `config.py`。

### 1.2 Bangumi 档案灌库（约 55.6 万条）

档案 = Bangumi 官方数据集，本项目只读 `subject.jsonlines`（**不含图片字段 → 封面全空**，见 `data-completeness-plan.md`）。

1. **先看规模**：统计各契约类型的条数分布
   ```bash
   python -m sync --source bangumi --archive dump.zip --stats
   ```
2. **小批量 dry-run 验证载荷**（不联系 Java，只落盘将要发送的载荷）
   ```bash
   python -m sync --source bangumi --archive dump.zip --limit 100 --dry-run
   ```
   检查 `runs/batch-*.json` 里的条目字段是否合理。
3. **抽代表性样本**（蓄水池抽样，消除「按 id 顺序取前 N 条」的偏差）
   ```bash
   python -m sync --source bangumi --archive dump.zip --sample uniform --limit 5000 --dry-run
   ```
4. **正式全量**（去掉 `--dry-run`，需 `OTAKU_INTERNAL_TOKEN`）
   ```bash
   python -m sync --source bangumi --archive dump.zip
   ```
   - **流式处理**：`iter_many` / `fetch_sample` 不整体载入内存，内存只保留当前批次（`batch_size`），可吃下全量 55.6 万条（全量整体载入外推约 900MB，故必须走流式）。
   - 纯本地 zip 读取，**不请求来源站网络**；限流只作用于「提交后端」阶段。

### 1.3 Otaku 站点灌库（约 1.8 万条）

默认来源即 `otaku_site`，读环境变量即可：

```bash
python -m sync            # 等价于 --source otaku_site，默认同步四类
```

- **串行拉取**，请求间隔 `0.6s`（≈ 1.67 req/s），遵守来源站限流口径（`page_size=200`、并发 1、每天 ≤ 5 万请求）。
- 来源站是公网服务，实测约 23 / 55 页会断连；抓取层有**指数退避重试 + 失败页记账**，跑一次收多少是多少，失败的页重跑补齐。

### 1.4 运行报告与失败补齐

每次运行在 `runs/` 下生成 `run-<时间戳>.json`（`RunReport`），终端也打印摘要。关键字段：

| 字段 | 含义 | 处理 |
|---|---|---|
| `fetched` / `accepted` / `rejected` | 抓取数 / 通过校验数 / 被拒数 | 被拒看 `rejected_items` 原因 |
| `batches[].delivered` | 每批是否送达后端 | 未送达需重跑该批 |
| `failed_pages` | 重试到底仍失败的页 | **非空 = 本次不是全量**，重跑同一命令补齐（按 `(source, source_id)` 幂等，不重复入库） |
| `server_error_items` | 被服务端故障拒绝的条目（如并发导入 `DuplicateKey`，Issue #81） | 数据本身没问题，用同一 `batch_id` 重跑补齐 |
| `rejected_items` | 数据问题（`TITLE_REQUIRED` / `INVALID_RELEASE_YEAR` 等） | 重试无益，需查源数据 |

### 1.5 注意事项

- **单批上限 500 条**（`--batch-size > 500` 直接报错退出）。
- **Ctrl-C 中断**会先落盘已完成报告，不会全丢。
- **封面**：bangumi 档案无图片字段，导入后 `cover_url` 全空（已知缺口，W3 路线 C 接受 + 客户端兜底）。
- **评分**：bangumi `score==0` 映射为 `None`（无人评分 ≠ 0 分），非空率约 36%（W3 不补）。

---

## 2. 定时化运行方案

### 2.1 现状

`sync-python` 是**一次性批处理**：`python -m sync ...` 跑完即退出，`__main__.py` 无内置 scheduler，需外部定时触发（`config.py` 注释已写明「需外部 cron」）。

### 2.2 推荐方案：外部调度

**不内置 scheduler**（避免常驻进程 + 多实例协调复杂度）。用操作系统级定时器：

- Linux / macOS：`cron` 或 `systemd.timer`
- 容器：镜像内 cron（如 `fcron`）或 Sidecar
- 开发机临时：本地 cron 暂代（无服务器时的过渡）

### 2.3 crontab 示例

```cron
# 每日 03:00 跑来源站全量（串行、限流内，约 1.8 万条）
0 3 * * *  cd /path/to/sync-python && /usr/bin/python -m sync --source otaku_site >> runs/cron.log 2>&1

# 每周日 04:00 跑 Bangumi 档案全量（静态快照，幂等重跑安全）
0 4 * * 0  cd /path/to/sync-python && OTAKU_ARCHIVE_PATH=/data/dump.zip /usr/bin/python -m sync --source bangumi >> runs/cron.log 2>&1
```

> 来源站每天 ≤ 5 万请求口径，单次全量 1.8 万条远低于此；Bangumi 档案不请求来源站网络。

### 2.4 限流 / 重试 / 失败记账（已在代码，方案层无需处理）

- **限流**：`OtakuSiteSource._throttle`，间隔 `0.6s`（可用 `OTAKU_REQUEST_INTERVAL_SECONDS` 调）。
- **重试**：`RETRYABLE_STATUS`（408 / 425 / 429 / 5xx）+ `TransportError`，指数退避 2 / 4 / 8s，`max_attempts=3`。
- **失败记账**：`failed_pages` 写进 `RunReport`，供重跑补齐。

### 2.5 监控告警

`RunReport` 已结构化，建议一个轻量后处理脚本（或 cron 后用 `jq` 检查）并告警：

- `failed_pages` 非空 → 告警「未全量，需重跑」（重跑同命令即可）。
- `server_error_items` 非空 → 告警「服务端故障，需重跑同 batch_id」。
- `rejected` 骤增 → 可能来源站字段变化，需人工看 `rejected_items` 原因。
- 建议把 `runs/run-*.json` 保留 N 天，便于回溯。

### 2.6 幂等与重跑策略

- 幂等由 `(source, source_id)` 唯一键 + 合并逻辑保证；`batch_id` 确定性（同输入同 `batch_id`）。
- 因此**每日全量重跑安全**：不会新增重复作品，内容变更走更新（验收 D2 / D3）。
- **增量可选**：`source.py` 预留 `search_raw`（`/api/contents/search`）未启用；当前用全量更简单可靠。

### 2.7 无服务器时的过渡

当前无生产服务器，sync 定时化**执行暂缓**（与 W3 回填、部署 Issue #78 同因——「服务器先按没有算」）。过渡方案：

- 开发机本地 cron 暂代（仅联调 / 小批量，不扛全量生产）。
- 待服务器到位：容器化部署 + 镜像内 cron，或独立调度服务。
- **文档先行**：本方案已就绪，服务器到位即可落地，不阻塞设计。

### 2.8 与未来目标的关系

通用化（PR #117）若启动，第二站接入会在 `source.py` 加新适配器；届时定时化需覆盖多来源调度，本方案的「外部 cron + 幂等重跑」范式仍适用，无需推翻。

---

## 3. 审查记录（sync 主责自查）

- **`#105` schedule-sync / `#110` article-sync**：在现有 `OtakuSiteSource` 上**追加** `fetch_schedule_page` / `iter_schedule_raw` / `fetch_articles_page` / `fetch_article_detail_html` 等方法，**复用** `_get()`（含 `_throttle` 限流 + 退避重试）、`RETRYABLE_STATUS`、`failed_pages` 记账，**没有另起限流逻辑**；`__main__.py` 用 `--schedule` / `--articles` 与 `--type` 互斥、限定 `otaku_site`，且都带测试。**规范符合度良好，可作为 sync 主责放行合入**。
- **技术债（记录，当前不改）**：`OtakuSiteSource` 随来源站功能增多持续膨胀；若未来启动通用化（多站），应按 PR #117 的方向把各来源端点拆为独立适配器 / 声明式映射。当前「单站点多端点」架构不阻塞。

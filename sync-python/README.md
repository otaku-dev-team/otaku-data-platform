# sync-python · 数据同步作业

从现有 Otaku 网站读取作品数据，清洗校验后经内部导入 API 提交给 Java 后端。

**当前状态**：骨架与清洗逻辑已实现，可脱离 Java 独立运行（dry-run）。
内部导入接口的实际行为待 `docs/openapi.yaml` 评审通过后按最终契约调整。

## 目录

```text
src/sync/
  config.py     配置，敏感值只从环境变量读取
  models.py     与 data-contract.md 对应的数据结构
  cleaning.py   清洗与校验（换行规范化、空值处理、评分校验）
  source.py     来源适配：现有网站的 JSON API
  importer.py   内部导入接口客户端：重试、幂等、失败记录
  pipeline.py   编排：拉取 -> 校验 -> 分批 -> 提交 -> 记录
  __main__.py   命令行入口
tests/          单元测试与本地桩服务
```

## 安装

```bash
pip install -r requirements.txt
```

## 运行测试

```bash
python -m pytest -q
```

已验证：29 项通过。测试使用本地桩服务，**不访问外网，不依赖 Java**，
覆盖验收项 D5（空标题拒绝）、D7（未授权拒绝）、D8（换行规范化）、D9（长文本不截断）、D10（重名各自成作品）。

## 脱离 Java 试跑（已验证）

只落盘将要发送的载荷与运行报告，不联系 Java：

```bash
PYTHONPATH=src python -m sync --type anime --limit 100 --dry-run --out runs
```

输出示例：

```text
[dry-run] 抓取 100，通过校验 100，拒绝 0，批次 1（已送达 0）
```

产物在 `runs/`：`batch-<batch_id>.json` 为将要提交给 Java 的载荷，`run-<时间>.json` 为运行报告。

已实测确认：回车换行已统一为 `\n`；封面、年份、标签一律为 `null`；评分尺度 `0-10`；
同一批输入重复运行得到**同一个** `batch_id`（幂等键），这是验收 D2「重跑不新增作品」的前提。

## 提交给 Java（待验证）

**以下命令尚未验证**，Java 后端与内部令牌就绪后才可用：

```bash
export OTAKU_INTERNAL_TOKEN=<内部导入令牌>
PYTHONPATH=src python -m sync --type anime --limit 100
```

## 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `OTAKU_SOURCE_BASE_URL` | `http://154.8.194.198:8000` | 来源站点 |
| `OTAKU_JAVA_BASE_URL` | `http://localhost:8080` | Java 后端 |
| `OTAKU_INTERNAL_TOKEN` | 无 | 内部导入令牌，**不得写入仓库** |
| `OTAKU_WORK_TYPES` | `anime` | 逗号分隔的作品类型 |
| `OTAKU_BATCH_SIZE` | `100` | 每批条数，上限 500 |
| `OTAKU_TIMEOUT_SECONDS` | `30` | 请求超时 |
| `OTAKU_MAX_ATTEMPTS` | `3` | 最大尝试次数 |
| `OTAKU_BACKOFF_SECONDS` | `2` | 重试间隔 |
| `OTAKU_OUTPUT_DIR` | `runs` | 产物目录 |

## 约定

- Python **不直接写业务数据库**，只通过内部导入 API 提交。
- 只有网络错误、超时、5xx、429 才重试；4xx 与认证失败不重试，直接记为未送达。
- 缺失字段传 `null`，不传空字符串、不填 0 分、不造占位值。
- 请求失败不静默吞掉，逐条记进运行报告，便于定位与重提。

# Bangumi 档案数据：同事怎么用起来

> 面向：@pyxz0 / @riceyu02，以及任何需要本地有数据的人。
> 2026-10-22 更新（`source_url` 已全链路打通，新导入的数据会带原页地址）。
>
> **一句话**：档案放在 draft release 里 → 登录 GitHub 下载 → 起后端 → 跑一条命令 → 全量约 15 分钟后库里有 55.6 万条。

---

## 0. 你需要哪一种

| 你的目的 | 用哪条路 | 耗时 |
|---|---|---|
| 只想让客户端列表 / 详情页有真数据可联调 | **1 万条均匀样本**（第 3 步的 B） | 约 2 分钟 |
| 要完整数据集、跑深页或性能验证 | **全量 55.6 万**（第 3 步的 C） | 约 15 分钟 |
| 只想知道档案里有什么 | 第 3 步的 A（`--stats`） | 25 秒 |

> 联调**不需要**全量。1 万条足够覆盖列表、详情、分页、收藏，且省磁盘。

---

## 1. 起后端（前置，缺了后面全白跑）

任选一种，详见 [`backend-java/README.md`](../backend-java/README.md)。

**方式 A：Docker（推荐，配置全给你配好了）**

```powershell
cd backend-java
docker compose up -d
docker compose ps          # 等 STATUS 变成 healthy，首次约 20–40 秒
$env:SPRING_PROFILES_ACTIVE = "local"
.\mvnw.cmd spring-boot:run
```

- MySQL 在宿主 **3307**（不占 3306，不会和本机已有 MySQL 打架）
- `local` profile 已经把数据库账号和内部令牌都配好：**令牌就是 `dev-token`**

**方式 B：用本机已装的 MySQL（没有 Docker 时走这条）**

⚠️ **不要加 `SPRING_PROFILES_ACTIVE=local`。** `application-local.yml` 里写死的是 compose 那套
（`localhost:3307` + 账号 `otaku/otaku123`），套到本机 MySQL 上会连不上。走**默认 profile + 显式环境变量**：

```bash
# 1) 建库（只建空库，表由 Flyway 启动时建）
mysql -h 127.0.0.1 -P 3310 -u root -p \
  < backend-java/src/main/resources/db/manual/00-create-database.sql

# 2) 起后端
cd backend-java
DB_HOST=127.0.0.1 DB_PORT=3310 DB_USER=root \
OTAKU_INTERNAL_TOKEN=dev-token \
./mvnw spring-boot:run
```

把 `3310` / `root` 换成你本机实例的实际端口与账号（端口用 `netstat -ano | grep 3306` 之类确认）。

**这两个变量必须显式传，别依赖默认值：**

| 变量 | 不传会怎样 |
|---|---|
| `DB_PORT` | 默认 **3306**。本机实例不在 3306 时直接连不上 |
| `OTAKU_INTERNAL_TOKEN` | 默认是**空**。空值时 `/internal/import/**` 全部返回 `401 内部导入接口未配置令牌，已禁用`，同步会一条都进不去（看着像后端没问题，实际全失败） |

导入时 Python 侧的 `OTAKU_INTERNAL_TOKEN` 必须与这里**一模一样**（都写 `dev-token` 最省事）。

**确认后端活着**（返回 `{"status":"UP"...}` 再往下走）：

```bash
curl http://localhost:8080/actuator/health
```

表不用手动建，Flyway 启动时自动跑迁移（含 `V3__work_source_url.sql`）。

---

## 2. 拿档案

### 2.1 下载

https://github.com/otaku-dev-team/otaku-data-platform/releases/download/untagged-1904bbf720d2aa41f91b/dump-subject-only.zip

- 这是一个 **draft release**（`data-bangumi-2026-10-21`），**必须先登录 GitHub、且对该仓库有写权限**才能看到 / 下载。未登录会直接 404，不是链接坏了。
- 也可以在 releases 页面里翻到草稿区下载。
- 文件：`dump-subject-only.zip`，**280,329,424 字节（268 MB）**。

> ⚠️ **不要把这份 draft 发布成正式 release。**
> 仓库是 **public**，一发布就等于把 268 MB 的 Bangumi 数据集对全网开放，违反数据集「不公开再分发」的条款，也超出团队授权范围。要给别人就私下传（网盘 / 对象存储），别走公开发布。
> 同理：这个 zip **不要提交进 git**。

### 2.2 校验（别跳过，传输损坏很常见）

| 平台 | 命令 |
|---|---|
| Windows PowerShell | `Get-FileHash .\dump-subject-only.zip -Algorithm SHA256` |
| macOS | `shasum -a 256 dump-subject-only.zip` |
| Linux | `sha256sum dump-subject-only.zip` |

正确值：`94d65e7e931b3d53d747476616429609ebfb93ffda212755086bb766956edfba`

两个版本对照（完整档一般不需要）：

| 版本 | 文件 | 大小 | SHA256 |
|---|---|---|---|
| 瘦身档（**推荐**，只剩适配器要读的 `subject.jsonlines`） | `dump-subject-only.zip` | 268 MB（280,329,424 字节） | `94d65e7e931b3d53d747476616429609ebfb93ffda212755086bb766956edfba` |
| 完整档（原始 9 个 jsonlines） | `dump.zip` | 426 MB | `19d12d42502fefeb4a2b14561cc978986a554320b06ca4bbf454d1830b101f90` |

两个版本导入结果**完全一致**（556,216 条），瘦身档只是少了 158 MB 用不上的文件。

### 2.3 放哪

放仓库**外面**，例如 `~/data/dump-subject-only.zip`。git 不跟踪它，放仓库里容易被误提交。

---

## 3. 导入

**以下命令都在 `sync-python/` 目录下执行**（不在这个目录，`PYTHONPATH=src` 会找不到模块）。

先装依赖：

```bash
cd sync-python
pip install -r requirements.txt
```

### A. 先看看档案里有什么（不连后端，25 秒）

```bash
PYTHONPATH=src python -m sync --source bangumi \
  --archive ~/data/dump-subject-only.zip --stats
```

实际输出长这样（四类相加 = **556,216**，最后一行是排除掉的音乐 / 三次元 / 画集等）：

```text
档案类型分布：
  anime  动画  31174
  comic  漫画  320631
  game   游戏  117295
  novel  小说  87116
  排除（音乐/三次元/其他书籍）  139693
```

### B. 1 万条样本（推荐先用这个）

```bash
PYTHONPATH=src python -m sync --source bangumi \
  --archive ~/data/dump-subject-only.zip \
  --type anime --type comic --type game --type novel \
  --sample uniform --limit 10000 --batch-size 500
```

`--sample uniform` 是**蓄水池随机抽样**，样本分布接近全量真实比例（按顺序取前 1 万条会严重偏向早期录入的知名作品）。
注意它必须配 `--limit`，不配会直接报错退出——这是故意的，避免你以为抽了样其实没抽。

### C. 全量 55.6 万

```bash
PYTHONPATH=src python -m sync --source bangumi \
  --archive ~/data/dump-subject-only.zip \
  --type anime --type comic --type game --type novel --batch-size 500
```

不加 `--sample` / `--limit` 就是全量，约 1,113 批。

### 需要先导出的环境变量

| 变量 | 值 | 说明 |
|---|---|---|
| `OTAKU_INTERNAL_TOKEN` | `dev-token` | **必须和后端那边设的同一个值**；用 `local` profile 就是 `dev-token`。为空则所有 `/internal/**` 返回 401 |
| `OTAKU_JAVA_BASE_URL` | `http://localhost:8080` | 后端地址，按实际改 |
| `NO_PROXY` | `localhost,127.0.0.1` | **本机有全局 `HTTP_PROXY` 时必须设**，否则 httpx 会把本地请求也丢给代理，报连不上 |

```bash
export OTAKU_INTERNAL_TOKEN=dev-token
export OTAKU_JAVA_BASE_URL=http://localhost:8080
export NO_PROXY=localhost,127.0.0.1
```

```powershell
$env:OTAKU_INTERNAL_TOKEN="dev-token"
$env:OTAKU_JAVA_BASE_URL="http://localhost:8080"
$env:NO_PROXY="localhost,127.0.0.1"
```

> 中断了直接重跑同一条命令。幂等由后端 `(source, source_id)` 唯一键保证，不会产生重复作品。
> 运行中每 50 批打一行进度；Ctrl-C 会**先落盘运行报告再退出**，报告在 `sync-python/runs/`。

---

## 4. 跑完怎么确认（别只看「没报错」）

**接口侧**

```bash
curl -s "http://localhost:8080/api/works?page=1&page_size=1"
```

`total` 应该 ≥ 你导入的条数（1 万样本 ≈ 10001，含一条早先的 smoke 数据；全量 ≈ 556217）。

**数据库侧**

```sql
SELECT source, COUNT(*) FROM work GROUP BY source;

-- 回流入口是否生效：新导入的数据 source_url 应有值
SELECT COUNT(*) FROM work WHERE source='bangumi' AND source_url IS NOT NULL;
```

`source_url` 这个查询应该**等于**该 source 的总数。如果为 0，说明你导入时用的还是**接收 `source_url` 之前的后端版本**（PR #55 之前），换个新分支重跑一次即可。

**抽查一条**（确认原页地址是人读页、不是 JSON 接口）

```bash
curl -s "http://localhost:8080/api/works?page=1&page_size=1" | head -c 400
# 取 work_id，然后
curl -s "http://localhost:8080/api/works/<work_id>"
```

`source_url` 形如 `https://bgm.tv/subject/8`，浏览器打开应该是 Bangumi 作品页。

---

## 5. 卡住了看这里

| 现象 | 原因 | 处理 |
|---|---|---|
| `ModuleNotFoundError: No module named 'sync'` | 没在 `sync-python/` 目录，或没设 `PYTHONPATH=src` | `cd sync-python` 后再跑，保留 `PYTHONPATH=src` 前缀 |
| `ModuleNotFoundError: No module named 'httpx'` | 没装依赖 | `pip install -r requirements.txt` |
| 连不上 `localhost:8080`、超时 | 全局代理把本地请求也代理了 | 设 `NO_PROXY=localhost,127.0.0.1` |
| `401` / 全部批次 delivered=false 报未授权 | 令牌不一致或后端没设 | 后端 `OTAKU_INTERNAL_TOKEN` 与 Python 侧必须**同一个值**；`local` profile 下默认是 `dev-token`，但**默认 profile 下默认是空，必须显式传** |
| `413 BATCH_TOO_LARGE` | `--batch-size` 超过 500 | 改回 500 或更小 |
| 拒绝连接 `127.0.0.1:3307` | Docker MySQL 还没起来 | `docker compose ps` 等到 healthy；`docker compose logs mysql` 看原因 |
| 后端启动报 `Communications link failure` / `Access denied` | 用了 `local` profile 但跑的是本机 MySQL（profile 里是 3307 + `otaku/otaku123`） | 去掉 `SPRING_PROFILES_ACTIVE=local`，改传 `DB_PORT` / `DB_USER`（见第 1 节方式 B） |
| 全部 `rejected`，原因 `TITLE_REQUIRED` | 档案路径给错、或给了完整档以外的文件 | 用 `--stats` 先确认能读出 556,216 条 |
| 下载链接 404 | 没登录 / 没有仓库写权限（draft release 特性） | 登录后再点，或让人私发 |

---

## 6. 预期结果与资源占用（本机实测）

| 指标 | 预期 |
|---|---|
| 匹配总量 | 556,216 条（anime 31,174 / comic 320,631 / game 117,295 / novel 87,116） |
| 批次数 | 约 1,113 批 × 500 |
| 耗时 | 服务端每批约 0.6 秒，全量 11–13 分钟；含 Python 侧约 15 分钟（1 万条约 1 分半） |
| Python 内存 | 峰值约 2.5 MB（流式攒批，不整体载入） |
| 数据库增量 | 约 600–700 MB（按 1 万条 ≈ 11 MB 外推） |
| 失败预期 | `rejected = 0`（1 万条已实测；全量同规则） |

**磁盘**：入库前确认数据目录所在盘剩余 ≥ 1 GB。本机之前就是因为 C 盘只剩 3.2 GB 没推全量——
空间不够就把 MySQL `datadir` 换到空间大的盘再导。

---

## 7. 为什么不能「直接给 zip 就完事」

后端只接受**已清洗的批次 JSON**（`POST /internal/import/batches`），不认 Bangumi 原始 jsonlines。
原始档案必须经 `sync-python` 的 `bangumi` 适配器转换：类型映射、`score=0 → null`、
`name_cn` 为空回落 `name`、`tags` 三态、`cover_url` 恒为 `null`、`source_url` 拼原页。

所以交接包 = **档案 + main 上的适配器代码 + 第 3 步那条命令**，三者缺一不可。
转换口径与实测缺口见 [`sync-python/README.md`](../sync-python/README.md)。

---

## 8. 已知数据缺口（不是 bug，别追）

| 缺口 | 比例 | 说明 |
|---|---|---|
| 无封面 | 100% | 档案**不含任何图片字段**，`cover_url` 恒为 `null`，客户端会显示占位 |
| 无中文名 | 78.9% | 回落后多为日文原名 |
| 无评分 | 58.8% | 档案里 `score=0` 表示无人评分，已映射为 `null`（不是 0 分） |
| 简介为空 | 17.8% | 档案本身没有 |

要补封面得另外去抓（受来源站限流约束），目前**没有做**，别当成导入失败排查。

---

## 9. 其他分发渠道（备用）

GitHub draft release 是首选（团队内、带权限控制）。若需要私下给仓库外的人：

| 渠道 | 适用 | 要点 |
|---|---|---|
| 网盘（阿里云盘 / 百度 / 123） | 异步、跨网络 | 搬瘦身档 268 MB，**附上本文与 SHA256** |
| 对象存储（COS / OSS / 七牛） | 需要稳定链接或多次分发 | 用带有效期的签名 URL，别开公共读 |
| 局域网 HTTP | 同网段、能当场接收 | 双方同时在线，放行端口 |

无论走哪个渠道，**校验 SHA256 再使用**。

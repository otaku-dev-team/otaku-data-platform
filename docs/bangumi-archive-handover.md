# Bangumi 档案数据交接说明

> 2026-10-21 · 负责人：zm · 面向：需要在自己环境导入数据的团队成员
>
> 本文只讲"怎么把档案变成库里的数据"。字段映射与实测口径见
> [`sync-python/README.md`](../sync-python/README.md)，契约见 [`openapi.yaml`](openapi.yaml)。

## 1. 交接物

提供两个版本，按分发渠道选择：

| 版本 | 文件 | 大小 | SHA256 |
|---|---|---|---|
| 完整档（原始 9 个 jsonlines） | `dump.zip` | 426 MB | `19d12d42502fefeb4a2b14561cc978986a554320b06ca4bbf454d1830b101f90` |
| **瘦身档（仅 `subject.jsonlines`，推荐分发）** | `dump-subject-only.zip` | **268 MB**（280,329,424 字节） | `94d65e7e931b3d53d747476616429609ebfb93ffda212755086bb766956edfba` |

- 完整档：解压后 `subject.jsonlines` 941 MB，另含 8 个本项目不用的 jsonlines。
- 瘦身档：只保留适配器实际读取的 `subject.jsonlines`，比完整档少 158 MB；
  已用 `--stats` 实测，类型分布与完整档**完全一致**（556,216 条），可直接替换使用。
- 两个版本都不进 git：属于外部数据集，且体积远超仓库适合的范围。

> 接收方下载后先核对上表 SHA256 再使用。

## 2. 为什么不能"直接给 zip 就完事"

后端只接受**已清洗的批次 JSON**（`POST /internal/import/batches`），不认 Bangumi 原始 jsonlines。
原始档案必须经 `sync-python` 的 `bangumi` 适配器做以下转换后才能入库：

- `type` / `platform` → `anime/comic/game/novel`（书籍按 platform 拆，音乐/三次元排除）
- `score == 0` → `main_rating: null`（不是 0 分）
- `name_cn` 为空 → 回落 `name`（不翻译、不丢条目）
- `tags` 的 `[]` 与 `null` 三态保留
- `cover_url` 恒为 `null`（档案无图片字段）

所以交接包 = **档案 + 已合并的适配器代码 + 下面这条命令**，三者缺一不可。

## 3. 导入步骤

前置：本机已起 Java 后端与 MySQL（见 `backend-java/README.md`），且分支已含
`feat/bangumi-archive-source` 的适配器（或已合并到 main）。

```bash
export OTAKU_INTERNAL_TOKEN=<内部导入令牌>
export OTAKU_JAVA_BASE_URL=http://localhost:8080     # 按实际后端地址改
export NO_PROXY=localhost,127.0.0.1                  # 本机有全局 HTTP_PROXY 时必须
PYTHONPATH=src python -m sync --source bangumi --archive <dump.zip> \
  --type anime --type comic --type game --type novel --batch-size 500
```

> 不加 `--sample` / `--limit` 即全量。中断后可用同一条命令重跑：
> 幂等由后端 `(source, source_id)` 唯一键保证，不会产生重复作品。
> 运行中每 50 批打印一次进度；Ctrl-C 会先落盘运行报告再退出。

## 4. 预期结果与资源占用（本机实测口径）

| 指标 | 预期 |
|---|---|
| 匹配总量 | 556,216 条（anime 31,174 / comic 320,631 / game 117,295 / novel 87,116） |
| 批次数 | 约 1,113 批 × 500 |
| 服务端耗时 | 每批约 0.6 秒（500 条），全量约 11–13 分钟；含 Python 侧总约 15 分钟 |
| Python 内存 | 峰值约 2.5 MB（流式攒批，不整体载入） |
| 数据库增量 | 约 600–700 MB（以 1 万条 ≈ 11 MB 外推） |
| 失败预期 | `rejected = 0`（已验证 1 万条样本；全量同规则） |

## 5. 分发渠道

| 渠道 | 适用 | 要点 |
|---|---|---|
| 网盘（阿里云盘 / 百度 / 123 等） | 异步、跨网络 | 最省事；上传瘦身档 268 MB，附本文与 SHA256 |
| 对象存储（腾讯云 COS / 阿里云 OSS / 七牛） | 需要稳定链接或多次分发 | 上传后生成带有效期的签名 URL |
| 局域网 HTTP | 同事同网段且能立即接收 | 需双方同时在线、放行端口，属同步传输 |
| GitHub Release | 团队内、有仓库权限 | 已上传为 **draft release** `data-bangumi-2026-10-21`（268MB 瘦身档）：https://github.com/otaku-dev-team/otaku-data-platform/releases/tag/untagged-1904bbf720d2aa41f91b 。draft 不公开发布，仅对仓库有写权限的成员可见 |

## 6. 注意事项

- **磁盘**：入库前确认数据目录所在盘剩余 ≥ 1 GB。本机曾因 C 盘仅剩 3.2 GB 而未推全量，
  需要时把 MySQL `datadir` 迁到空间充足的盘再导。
- **档案使用许可**：按 Bangumi 数据集的使用条款使用，不公开再分发；团队内部导入即可。
- **封面/中文名/评分缺口**：档案本身没有封面字段，78.9% 无中文名，58.8% 无人评分。
  这些是数据事实，不是导入失败，别当 bug 追。

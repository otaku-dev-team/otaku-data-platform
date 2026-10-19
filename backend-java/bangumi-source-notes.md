# 后端接入提醒：新增 `bangumi` 数据来源

> 来源：Python 负责人（sync-python，分支 `feat/bangumi-archive-source`）
> 对象：backend-java 负责人
> 背景：sync-python 已支持第二种数据来源——Bangumi 官方数据集档案（本地 jsonlines 快照）。
> 本文件列出 Java 侧（接口② / ③④）需要配套处理的点；不处理的话，第一批 bangumi 记录会被拒或语义错位。

参考契约：`docs/stage1-minimal-contract.md`、机器可读版 `docs/openapi.yaml`。

---

## 1. 最关键：放开 `source` 的取值（否则第一条就被拒）

当前 `openapi.yaml` 中接口②的请求体把 `source` 写死为枚举：

```yaml
# docs/openapi.yaml  ImportBatchRequest
source:
  type: string
  enum: [otaku_site]      # ← 会直接拒绝 bangumi
```

`Work.source` 的说明与示例也都是「第一阶段只有 otaku_site」。

而 bangumi 适配器提交时，**批次级 `source` 一律为 `"bangumi"`**（依据契约 §4.6「新增一个网站 = 加一个 source 取值 + 一份适配器配置」）。若后端把 `source` 做成 `otaku_site` 白名单校验，第一条 bangumi 记录就会拿到 `400 BAD_REQUEST`，整批被拒。

**后端要做**：把 `source` 从固定枚举改为可扩展（至少接受 `otaku_site` 与 `bangumi`，或直接放开为不校验的自由字符串）。`(source, source_id)` 唯一约束逻辑不受影响——不同 `source` 的 `source_id` 本就是两个作品（契约 §3.1、§4.6）。

---

## 2. `source_id` 是字符串，Bangumi 的 id 是数字

契约 §2.1 已要求 `source_id` **字符串存储**（"原站作品 id，字符串存储避免数值歧义"）。bangumi 的 `subject_id` 是 int（如 `12345`），Python 会转成字符串 `"12345"` 提交。

**后端要做**：确认按字符串存、按字符串比对即可，无需额外改动。

---

## 3. `cover_url` 对 bangumi **永远为 `null`**

契约 §2.1：`cover_url` 由 Java 代理 + 本地缓存来源地址。**但 bangumi 档案里没有任何图片字段**，Python 提交时 `cover_url` 一律为 `null`（不伪造图床地址——档案里没有这个字段，构造出来就是假数据）。

⚠️ 与 otaku_site 的本质区别：

| 来源 | Python 提交的 cover_url | Java 行为 |
| --- | --- | --- |
| `otaku_site` | 总是带一个来源站绝对地址（如 `http://154.8.194.198:8000/media/full/cover_313852.jpg`） | 回源代理 + 本地缓存，对外换平台地址 |
| `bangumi` | **恒为 `null`**（档案无图） | 直接存 `null`、对外返回 `null`，**不要尝试回源** |

**后端要做**：封面代理逻辑在 `cover_url == null` 时直接存 `null`、对外返回 `null`，不要因为没有来源地址而报错或去回源。客户端按契约 §6.3 走占位图即可。

---

## 4. `tags` 的 `[]` 对 bangumi 是「明确无标签」，别归一化成 `null`

契约 §2.3 的三态语义：

- `null` = 本次没拿到，不覆盖已有值
- `[]` = 明确无标签，可清空
- 有值 = 覆盖

otaku_site 适配器把空标签统一转 `null`（因站点无法区分两种空值，见 §4.4.3）。**bangumi 不转**：档案是静态快照，`[]` 就是「快照里没有标签」这个事实，按契约原样保留 `[]`。

**后端要做**：Java 侧必须真的区分 `[]` 与 `null`，**不要**在入库时把 `[]` 当 `null` 处理或反过来。否则 bangumi 的「明确无标签」语义会丢失；未来 otaku_site 一旦能区分两种空值，这条逻辑同样会错。

---

## 5. `main_rating.source` 会是 `"bangumi"`

评分对象（非批次级）里的 `source` 字段，bangumi 记录会是 `"bangumi"`，`scale` 仍是 `"0-10"`。`openapi.yaml` 的 `SourceRating.source` 是自由字符串、未做枚举校验；若后端对评分对象里的 `source` 也加了 `otaku_site` 白名单，同样会拒，请一并放开。

---

## 6. 建议的联调顺序

1. 先拿 **1 条** bangumi 记录打接口②，确认：
   - `source=bangumi` 不被拒；
   - `cover_url=null` 不报错；
   - `tags=[]` 正确清空（若库里原本有标签）；
   - 正常返回 `work_id`。
2. 再上 500 条一批，观察 `counts`（inserted / updated / unchanged / rejected）。
3. 最后再决定全量或先推 1 万条（见第 7 节）。

> 后端未就绪前，Python 侧已生成 **10,000 条 bangumi 真实载荷**（dry-run 落盘于 `sync-python/runs/`，20 个批次、0 拒绝、`source_id` 无重复）。后端一就绪即可推送，命令见对应 PR 描述。

---

## 7. 全量规模（供后端评估吞吐，非必须现在处理）

bangumi 档案在四类契约类型下的全量条数（Python 全量实测）：

| 类型 | 条数 |
| --- | --- |
| anime | 31,174 |
| comic | 320,631 |
| game | 117,295 |
| novel | 87,116 |
| **合计** | **556,216** |

当前 Python 实现会把全量先载入内存再分批（实测外推约 900 MB 峰值内存），所以首批建议先推 1 万条；**全量推送前 Python 侧需先把分批改成流式**。此事与后端无关，仅作规模预期。

---

## 8. 一句话汇总给后端改的点

1. `source` 枚举放开（接受 `bangumi`）；
2. `cover_url=null` 时别回源、直接存空；
3. `tags` 的 `[]` 与 `null` 三态语义必须真区分；
4. 评分对象内 `source` 若有白名单也一并放开。

其余字段（`work_type` 四值、`title`、`summary`、`main_rating` 形态、`source_id` 字符串）均与契约一致，无需特殊处理。

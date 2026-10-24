# 阶段 3 可靠性验收记录（E1–E8）

对应 `acceptance.md` §4。这份记录把「谁在什么环境下验的」写清楚，
因为阶段 3 的多数结论来自接口层，且**验的时候后端进程的版本会直接影响结论**（见 §1）。

**日期**：2026-10-22
**环境**：本机 MySQL 8.0.46（`127.0.0.1:3310`）+ Spring Boot 8082，代码为 `main`（`d71f532`）
**数据**：库内 15,445 条（`otaku_site` 15,318 + `bangumi` 127）
**测试数据**：全部标 `source='e2e-probe'`，跑完已清理，库恢复 15,445 条

---

## 0. 总览

| # | 检查项 | 结果 | 谁验的 / 依据 |
|---|---|---|---|
| E1 | 重复导入相同来源数据，作品数与映射数不增长 | | zm 的 API 层验收（同批重跑 `unchanged=1`，总数不翻倍） |
| E2 | 来源字段变更后导入，`work_id` 不变 | | zm 的 API 层验收（同 `source_id` 改标题两次，`updated=1`，`work_id` 恒定） |
| E3 | 写入成功但响应丢失后重试，无重复作品 | | 本次（同 `batch_id` 重提得到 `unchanged`，非重复插入） |
| E4 | 坏记录可追踪，并能通过 `batch_id` 定位、重提被拒记录 | | **本次补完**（zm 只验到「坏记录被拒 + 错误码」） |
| E5 | 来源不可用，保留上次成功数据，不清空 | | **本次补完** |
| E6 | 越权写入被拒 | | zm 的验收（无 `X-Internal-Token` → 401），本次复核 |
| E7 | 越权读取：不能读取或修改他人个人数据 | | **本次补完**（此前只覆盖「读不到」，没覆盖「改不动」） |
| E8 | 新人按 README 能独立启动服务并跑通两端 | | PR #74 clean-room 演练（干净克隆 2.8MB → 3.9 秒启动 → 导入 → 双端跑通） |
| 附 | 并发导入（两个作业同时提交同一批） | | **本次补测**：数据一致；当时错误分类有缺陷，已由 PR #84 修复，见 §5 末 |
| 附 | 中断恢复（提交到一半进程被杀） | | **本次补测**：500 条崩溃留 123 条，重跑补到 500/500，见 §6 |

**结论：E1–E8 全部通过。**

---

## 1. 先看这一条：验阶段 3 前必须确认后端进程的版本

本次遇到一次假故障，值得记下来：

- 本机 8080 上有个后端实例，**01:55:14 启动**
- 而 PR #59（导入批次逐轮明细 `import_batch_run`）**02:05:16 才合入 main**
- 结果：`GET /internal/import/batches/{id}?with_runs` 返回的 JSON 里**没有 `runs` 字段**，
  `import_batch.run_count` 三次提交后仍是 **0**，`import_batch_run` 表里一条记录都没有

差一点把它当成「PR #59 的功能没写对」。用最新代码重启后：

- `?with_runs` 返回 `runs`，逐轮 `run_seq=1`、`run_seq=2` 都在
- `run_count` 正常自增

**判定方法**：`GET /actuator/health` 只能证明进程活着，**证明不了它是最新代码**。
验阶段 3 前先确认进程启动时间晚于最后一次后端合并，或者干脆用新端口起一个干净实例。
只 `mvn spring-boot:run` 而不 `clean` 也有风险——`target/classes/db/migration/` 会残留旧迁移文件。

---

## 2. E4 · 坏记录可追踪，并能重提

**场景**：一批里混着正常记录和脏数据。运维需要能回答「哪条被拒了、为什么、能不能补」。

| 步骤 | 操作 | 结果 |
|---|---|---|
| 1 | 提交 3 条：1 正常 + 空标题 + `release_year=1800` | `inserted=1`、`rejected=2` |
| 2 | 看拒收明细 | `TITLE_REQUIRED`（title 为空）、`INVALID_RELEASE_YEAR`（应为 1900–2100，实际 1800），**逐条带 `source_id`** |
| 3 | `GET /internal/import/batches/{batch_id}` | 200，能按 `batch_id` 查回整批结果 |
| 4 | `GET ...?with_runs` | 200，`runs` 有 1 条，含该轮的 counts 与 errors |
| 5 | 修正那 2 条后**用同一个 `batch_id` 重提** | `inserted=2`、`rejected=0` |
| 6 | 再查 `?with_runs` | `runs` 变成 2 条，`run_seq=1/2`——**同一批次保留了每一轮** |

**判定：通过。** 坏记录能定位（`batch_id` + `source_id` + `code`），修正后能补进去，且历史不被覆盖。

> 注意：后端**刻意不做「同 `batch_id` 直接返回上次结果」的短路**（见 `ImportBatchRepository` 注释）。
> 原因是 Python 的 `batch_id` 只哈希 `source_id` 集合、不含字段内容，短路会让「改评分应更新」永远不生效。
> 所以「重提」是真实执行 upsert，不是回放缓存——这正是 E3 能成立的基础。

## 3. E5 · 来源不可用不清空

**场景**：来源站挂了、或者这次抓到一堆脏数据。库里已有的作品和个人数据**不能被连带清掉**。

| 步骤 | 操作 | 结果 |
|---|---|---|
| 1 | 记录基线 | `total=15,448` |
| 2 | 提交整批脏数据（3 条全部会被拒） | 全部 `rejected`，无一入库 |
| 3 | 复查总数 | `total=15,448`，**未变化** |
| 4 | 提交空批次（来源这次零结果） | `inserted=0/rejected=0` |
| 5 | 复查总数 | `total=15,448`，**未变化** |
| 6 | 同时查 A 的收藏 | `total=2`，未受影响 |

**判定：通过。** 导入失败是「没有新增」，不是「清空重来」。

> 这也是设计上的必然：导入是逐条 upsert，没有任何「按 source 删除再重建」的路径。
> 但验收要求把它钉住，避免以后有人为了「让库和来源完全一致」加一条 truncate。

## 4. E7 · 越权读取：读不到，也改不动

**场景**：B 拿到 A 收藏过的作品 ID，能不能读到 / 改掉 A 的状态。

| 步骤 | 操作 | 结果 |
|---|---|---|
| 1 | A 收藏作品 `W-…` 并设 `want` | 200 |
| 2 | B 读同一作品 | 200，`collected=false` —— **看不到 A 的状态** |
| 3 | B 改同一作品状态为 `watched` | **409 `COLLECTION_REQUIRED`**（B 自己没有这条记录） |
| 4 | A 复查 | `collected=true`、`status=want` —— **A 的数据没被改动** |
| 5 | B 删除同一作品 | 204（删的是 B 自己的空记录） |
| 6 | A 复查 | `collected=true` —— **A 的收藏仍在** |
| 7 | 无 Token 读该接口 | 401 |

**判定：通过。**

第 3 步是关键：写接口是「以当前用户的 `user_id` + `work_id` 定位记录」，
B 找不到自己的记录就返回 409，**不会顺着 `work_id` 去改 A 的行**。
第 5 步同理——`DELETE` 按 `(user_id, work_id)` 定位，A 的记录不在 B 的可见范围内。

---

## 5. 并发导入（2026-10-22 补测）——数据没丢，但错误分类是错的

E1–E7 验的都是串行。这一节补并发：**两个同步作业同时跑同一份数据**会怎样。

### 场景与结果

| 场景 | 并发数 | 响应 | 最终入库 |
|---|---|---|---|
| A 同一个 `batch_id`，相同 50 条 | 2 | 请求1：`inserted=0 unchanged=25 rejected=25`<br>请求2：`inserted=50` | `a-*` **50** ✓ |
| B 不同 `batch_id`、相同 50 条 | 2 | 请求1：`inserted=11 unchanged=19 rejected=20`<br>请求2：`inserted=39 unchanged=8 rejected=3` | `b-*` **50** ✓ |
| C 同一个 `batch_id`，相同 100 条 | 5 | 五次分别 `rejected=51/51/49/30/42` | `c-*` **100** ✓ |

**数据完整性是守住的**：唯一键 `(source, source_id)` + upsert 保证了不会产生重复作品。
三个场景合计入库 200 条，与预期完全一致，零重复。

### 根因：兜底逻辑被隔离级别打败（不是「没有兜底」）

> 这一节修正过一次。第一版把根因写成「`apply()` 没有兜底，异常被直接归类」，
> 但读代码发现**第 201–206 行已经有 `DuplicateKeyException` 兜底**。真实原因更微妙。

`ImportService.apply()` 的实际结构：

```java
return transactionTemplate.execute(status -> {
    Optional<WorkRecord> existing = findBySourceKey(source, item.sourceId());  // ① 建立快照
    if (existing.isPresent()) return updateExisting(existing.get(), item);
    try {
        workRepository.insert(created);          // ② 撞唯一键，InnoDB 会等 A 提交
        return INSERTED;
    } catch (DuplicateKeyException ex) {
        WorkRecord current = findBySourceKey(source, item.sourceId())
                .orElseThrow(() -> ex);          // ③ 查不到 -> 重抛原异常
        return updateExisting(current, item);    //   「退化为更新」的兜底
    }
});
```

链条：

1. 事务 B 执行 ①，此时 A 还没提交 → **快照里没有这条记录**
2. B 执行 ②，唯一键检查会等 A 提交，然后抛 `DuplicateKeyException`
3. B 在 catch 里执行 ③ 再查 —— **但 `REPEATABLE READ` 下，这个事务的一致性读快照在 ① 就固定了**，
   ③ 看到的还是空 → `orElseThrow(() -> ex)` 把原异常抛出去
4. 外层 `catch (Exception)` 记成 `rejected` + `INTERNAL_ERROR`

环境已确认：`SELECT @@transaction_isolation` → **REPEATABLE-READ**，
JDBC URL 与 `application.yml` 都未指定隔离级别。

**所以那条「退化为更新」的兜底，在真实并发下基本不会生效**——它只在二次查询碰巧能看到新数据时才有用。

### 为什么这是个真问题

不是「数据丢了」，而是**语义错了，而且会导致数据丢**：

- `rejected` 在契约里的含义是「这条数据本身有问题，重试没用」（比如 `TITLE_REQUIRED`）
- 而 `DuplicateKeyException` 是**并发竞争**，重试就能成功
- 同步侧如果按「`rejected` 不重试」处理（这是合理策略），这些记录就**静默消失**

本次没丢，是因为另一边恰好插入成功了。如果两个请求都各自部分失败，或者某个批次的
成功方整体回滚，就会真丢。

### 建议修法（未实施，留给 @pyxz0 判断）

1. **兜底里改用当前读**：把 ③ 的 `findBySourceKey` 换成 `SELECT ... FOR UPDATE`（读最新已提交版本，
   绕过快照），或者用一个 `REQUIRES_NEW` 的独立事务去读——新事务 = 新快照。
   （注意：现有的「重新读一次」写法属于同一事务，改不动这个问题的根本原因）
2. **或** 把 `workRepository.insert()` 换成 `INSERT ... ON DUPLICATE KEY UPDATE`（原子，不依赖二次查询）。
3. **无论选哪个，`INTERNAL_ERROR` 都不该计入 `rejected`**——它是服务端故障，
   应当返回 5xx 或单独的 `failed` 计数，让调用方能区分「重试有用」和「重试没用」。

第 3 条与前两条独立，即使不修并发也应该改：现在这个分类会让同步侧误判，进而静默丢数据。

### 结论（2026-10-22 补记，已修复）

**Issue #81 已由 PR #84 修复并关闭。** 采纳的是建议 1 的后半句（换新事务 = 新快照），
实现上拆出 `applyOnce`、由 `apply` 在撞键后重试一次；接口、幂等语义、`Counts` 口径均未变。
没选建议 1 前半句（`FOR UPDATE`）与建议 2（`ON DUPLICATE KEY UPDATE`）的理由见 PR #84 正文。

真实 MySQL 8.0 上三场景实测：

| 场景 | 修复前 | 修复后 |
|---|---|---|
| 同 `batch_id`，2 并发 × 50 条 | `rejected=30` | **0** |
| 不同 `batch_id`，2 并发 × 50 条 | `rejected=31` | **0** |
| 同 `batch_id`，5 并发 × 100 条 | 五路各丢 60–90 条 | **0** |

回归测试 `ImportConcurrencyIntegrationTest` 已进 CI（workflow 起 `mysql:8.0`）。
**建议 3（`INTERNAL_ERROR` 单列 `failed` 计数）仍未做**：属响应形状变更，需三人确认；
同步侧已按 PR #82 分开记录，短期不受影响。

## 6. 中断恢复：提交到一半进程被杀，会留下什么

**场景**：提交 500 条（契约上限）的过程中，用 `taskkill /F` 强杀后端进程。

| 阶段 | 结果 |
|---|---|
| 崩溃后库里 | **123 条**（500 条中的 123 条已提交） |
| 崩溃后 `import_batch` | **没有记录** |
| 崩溃后 `import_batch_run` | **没有记录** |
| 重启后重跑同一批 | `inserted=377, unchanged=123, rejected=0` |
| 最终 | **500 / 500 条，重复 0** |

### 为什么会有 123 条残留

`ImportService.apply()` 里每条记录一个 `transactionTemplate.execute(...)`，
**逐条独立事务**。已提交的 123 条不会因为进程被杀而回滚——这是正常的、也是想要的
（否则一次崩溃就要从头重跑）。

`import_batch` / `import_batch_run` 的写入发生在**全部处理完之后**，所以崩溃时还没轮到它。

### 恢复靠的是幂等，不是事务

重跑时那 123 条命中 `findBySourceKey` 走 `unchanged`，剩下的 377 条正常插入。
所以「崩溃 → 重跑」这条路是通的，**不会重复也不会丢**。

### 可观测性上的一个空缺

崩溃的那次尝试**没有留下任何记录**：批次表和明细表都查不到 `e2e-interrupt-01`。

运维无法从批次表看出「这批曾经失败过一次」，只能从「`work` 里有 123 条数据但批次记录不存在」
这种间接证据反推。如果要补，可以在请求进来时先写一条 `status=running` 的记录，
结束后更新——但这属于可观测性改造，不在本次验收范围内。

## 7. 没覆盖到的

- **E8 新人上手**：由 PR #74 的 clean-room 演练负责（换一台干净机器、只看 README 能否跑起来）。
  本机环境被我改过多次（MySQL 3310、模拟器、旧后端进程），不能算「新人」。
- **并发导入**：已补（见 §5），缺陷已由 PR #84 修复并关闭 Issue #81（回归测试进 CI）。
  **仍未做**的是建议 3：把 `INTERNAL_ERROR` 单列成 `failed` 计数（响应形状变更，需三人确认）。
- **超大批次**：单批 500 条（契约上限）的中断恢复已验（见 §6）。但**没验「1100 批连续跑完」**
  这种量级——真实的 55.6 万条全量导入会分成 1100 多批，中途出问题时的表现和单批不同
  （比如批次表积累、磁盘增长、连接池耗尽）。
- **UI 侧**：阶段 3 全是服务端行为，客户端不参与。

---

## 复现方式

脚本逻辑见 PR 描述。要点：

1. 用**最新代码**起一个干净实例（不同端口，避免动别人的进程），`mvn clean` 后再启动
2. 所有测试数据打 `source='e2e-probe'` 前缀，跑完按 source 与 `batch_id LIKE 'e2e-probe%'` 删除
3. 测完核对 `SELECT COUNT(*) FROM work` 回到基线

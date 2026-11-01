# 文档索引

> 本页只做文档导航。**项目目标、技术栈与分工、协作规则、完成标准见仓库根目录 [`README.md`](../README.md)**，这里不再重复。

## 一、当前生效的契约

第一阶段实现以此为准：

- [`docs/stage1-minimal-contract.md`](stage1-minimal-contract.md)：**四个接口的边界与数据格式**——① 网站接入（网站→平台）、② 数据写入（Python→Java）、③ 作品列表、④ 作品详情（Flutter→Java）；另含最小字段集（10 个字段、仅 4 个必填）、唯一标识两层规则、可空规则与创建/更新规则。
- [`docs/openapi.yaml`](openapi.yaml)：上面契约的**机器可读版本**，覆盖接口②③④的请求与响应形状，以及 ③④ 共用的封面代理出口 `GET /api/covers/{work_id}`。接口①不在其中——那是平台只读拉取来源站，来源站接口不由我们定义。

## 一之二、项目总纲与授权

- [`docs/project-charter.md`](project-charter.md)：**项目总纲**——总目标 G1–G3、六条工作流 W1–W6、两个探索项、授权与自治规则、必须回来确认的红线、验收与信任机制。**先读这一份再看其他。**
- [`docs/collaboration-protocol.md`](collaboration-protocol.md)：**并行开发时的阻塞处理**——三类阻塞各怎么应对、「确认默认同意、沉默不阻塞」（PR 是通知不是闸门）、冲突归作者解。**开工前读一遍，省掉等点头的时间。**
- [`docs/ROADMAP.md`](ROADMAP.md)：唯一看板，含阶段总览（§6）与工作流看板（§8）。
- [`docs/product-positioning.md`](product-positioning.md)：**上位依据**（2026-10-24 起，定位 > 契约 > 其他文档）——商业模式、身份归属、六条边界、运营形态三态（附录 A：站点生命周期与关停预案）。技术判断有分歧时以它为准。
- [`docs/merge-queue.md`](merge-queue.md)：合并队列与合并后动作清单——栈关系、四批合并顺序、合并后要关 / rebase 的分支、三个已知坑。合并期间以这份为准。

## 二、草案与背景材料

以下为阶段 0 起草的材料，供追溯与评审；**与上一节冲突时以上一节为准**。

- [`docs/data-contract.md`](data-contract.md)：完整数据契约草案（含后续阶段字段），含来源站实测数据事实。
- [`docs/stage2-account-collection-contract.md`](stage2-account-collection-contract.md)：**第二阶段（账号与收藏）契约**，对应验收 C1–C11。含 8 个接口、新增错误码与 C1–C11 的逐条映射。**已实现并双端验收**（2026-10-21，见 [`stage2-acceptance.md`](stage2-acceptance.md)），接口已落 `openapi.yaml`。
- [`docs/w1.3-notification-proposal.md`](w1.3-notification-proposal.md)：**W1.3 通知触达方案草案**。建议拆成「本地提醒（纯客户端，可立即做）」与「服务端推送（需新增设备令牌端点，属红线）」两半；含端点、字段、表结构与事件载荷的提议。**尚未生效**，需三人确认。
- [`docs/acceptance.md`](acceptance.md)：双端浏览、跨端个人管理与同步可靠性的逐条验收步骤；第 6 节是**阶段 1 实测记录**（2026-10-21，B1–B11 全部通过）。
- [`docs/stage2-acceptance.md`](stage2-acceptance.md)：阶段 2 双端实测记录（2026-10-21，Windows 桌面 + Android），含 §8 用例与 C1–C11 的覆盖对照。
- [`docs/stage3-performance-baseline.md`](stage3-performance-baseline.md)：**万级列表的滚动基线**（2026-10-21 实测）。含帧耗时、内存曲线、分页请求数与两个真实瓶颈（封面重复回源、封面按原图解码），以及复现脚本的用法。
- [`docs/stage3-reliability-record.md`](stage3-reliability-record.md)：阶段 3 可靠性实测记录。
- [`docs/identity-auth-endpoint-playbook.md`](identity-auth-endpoint-playbook.md)：站点授权端点预案与联调手册——标准 OAuth 授权码四端点、三点安全调整、self-revoke 三态、联调配置（凭据存环境变量，不入库）。
- 平台侧令牌交换代理联调契约草案（PR #147，待三人确认）：用户表加列、账号映射与收藏迁移设计。
- [`docs/site-owner-console-proposal.md`](site-owner-console-proposal.md)：**站主运营后台立项草案**（#144）——范围、权限模型、「禁用 ≠ 封网站账号」的边界，以及六项拍板结论；实现已落地，见下一行。
- [`docs/site-owner-console.md`](site-owner-console.md)：**站主后台使用说明（首版）**——站主能做什么/不能做什么、数据隔离怎么保证、平台运维怎么开通站主、禁用到底禁了什么、已知未做。
- [`docs/data-completeness-plan.md`](data-completeness-plan.md)：数据缺口体检与补齐路径（封面 / 评分 / 简介三线，结论：封面走 C+A）。
- [`docs/db-intake-dataset.md`](db-intake-dataset.md)：**数据库直读方案**——库与接口是**两个正交维度**（交付形态 ≠ 数据入口，私有化不等于能给库）；SQLite 无授权体系故只能物理隔离（派生库）、结构耦合压进声明式映射 + 三档缺列处置（主键消失即停机）、参照 Airbyte/dlt/dbt 却不引入的理由，以及 `sync-dataset` 导出 → 提交两段的落地状态与待办。
- [`docs/开源参考与可借鉴项.md`](开源参考与可借鉴项.md)：**外部开源项目的调研记录**（不做任何代码改动）——九个参考项目，只留结论和入口：按「想法 / 小段实现 / 整文件」三档给抄的分寸，含「通用客户端」类（mihon / Suwayomi / legado）为什么都对不上我们的定位，以及对照出来的两处真差距（收藏表缺版本号与墓碑、筛选参数全局固定）。细节走「先看哪儿」的直链，自己去看源码；末尾「落到谁头上」列了谁做、能不能现在做、量多大（sync 侧 0 项，理由在文里）。
- [`docs/person-id-unification.md`](person-id-unification.md)：**人物 id 口径统一**——原先 `people.source_id`（网站自增）与 `person_ref`（Bangumi 人物 id）是两套 id 空间、4,115 个数值撞车；**已定案**改前缀键（`bgm:` 强关联 / `pname:` `cname:` 弱关联），人物与公司端点形状照首站（`/cast/{id}`、`/studios/{name}`）。含证据链、三档范围与已定案的三条。

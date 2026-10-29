-- 软删（#249 / docs/deletion-semantics-proposal.md）
--
-- 源站删掉的作品**不物理删**：收藏、历史、外部引用都指着它，物理删等于替用户删数据，
-- 源站误删/回滚时也没法恢复。这里只打一个时间戳，对外查询一律过滤。
--
-- 为什么是 datetime 而不是布尔 is_deleted：
-- 1. 时间点能回答「什么时候下的架」，排障和运营对账都要；
-- 2. NULL 天然表示「正常」，19.8 万既有行不需要回填，迁移是纯加列。
--
-- 注意（§6.1）：软删行仍然占着 (source, source_id) 唯一键，所以导入的 upsert
-- 必须把 deleted_at 置空（复活），否则「重新导入了却搜不到」，且不报任何错。
ALTER TABLE work
    ADD COLUMN deleted_at DATETIME(3) NULL DEFAULT NULL
        COMMENT '软删时间（UTC）。NULL = 正常；非空 = 已下架，列表/搜索/筛选不再返回';

-- 不加 deleted_at 单列索引：99% 以上是 NULL，等值/范围查询都用不上它；
-- 真要按「已下架」筛（运营对账）是全表扫，198 万行以内都在百毫秒级，不值得为它付写入成本。

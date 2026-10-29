-- 平台代存 UGC：回复（#240 B2c②）
--
-- 只做**一层**回复：parent_id 只能指向顶层评论（parent_id IS NULL 的行）。
-- 不做无限嵌套的理由：两层已经覆盖「评论 + 追评」的实际用法，再深的树在手机上
-- 只能靠缩进硬撑，且分页、审核、删除三处都会变复杂。要更深时再开新档，不预留半成品。
--
-- 不建自引用外键，理由与 work_id 不建外键相同：用户内容之间不互相绑死。
-- 而且软删是本表的删除方式（从不物理删行），外键只会让清理测试数据时受拓扑顺序约束。
--
-- 索引重排的原因：顶层列表多了 parent_id IS NULL 这个条件，旧索引
-- idx_ugc_work_created(site_key, work_id, status, created_at) 的第三列是 status，
-- parent_id 只能回表过滤。新索引把 parent_id 提到 status 之前，让「顶层 + 已发布 + 时间序」
-- 一次走完；回复按父查用的是第二条索引。
ALTER TABLE ugc_comment
    ADD COLUMN parent_id BIGINT UNSIGNED NULL
        COMMENT '回复的目标顶层评论 id；NULL = 顶层评论（只允许一层，回复不能再被回复）',
    DROP INDEX idx_ugc_work_created,
    ADD KEY idx_ugc_work_parent_created (site_key, work_id, parent_id, status, created_at),
    ADD KEY idx_ugc_parent_created (site_key, parent_id, status, created_at);

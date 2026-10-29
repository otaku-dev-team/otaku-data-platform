-- 平台代存 UGC：评论编辑（#240 B2c④）
--
-- 为什么单独一列而不是复用 updated_at：updated_at 会被「站主隐藏 / 恢复 / 软删」更新，
-- 用它判断「作者改过内容」会把审核动作也算进去。edited_at 只在作者改正文时写，
-- 客户端据此显示「已编辑」，站主据此判断是否需要重审。
ALTER TABLE ugc_comment
    ADD COLUMN edited_at DATETIME(3) NULL
        COMMENT '作者最后一次修改正文的时间；NULL = 从未编辑';

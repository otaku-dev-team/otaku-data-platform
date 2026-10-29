-- UGC 第二档：站主开关 + 审核（#240 B2a）
--
-- 产品口径（product-positioning.md §A.4）：A 模式的平台代存 UGC 是**可选增值**，
-- 由站主在后台开启；未开启时客户端跳原页补位。所以默认必须是**关**——
-- 默认开启等于替站主做了「要不要在自己站上承载用户内容」这个合规决定。
ALTER TABLE site
    ADD COLUMN ugc_enabled TINYINT(1) NOT NULL DEFAULT 0
        COMMENT '站主是否开启平台代存 UGC（作品评论）。0=未开启：写接口 403，客户端跳原页';

-- 后台审核列表：按站点 + 状态 + 时间倒序翻页。
-- 现有的 idx_ugc_work_created 前缀是 work_id，后台按站点查用不上。
ALTER TABLE ugc_comment
    ADD KEY idx_ugc_site_status_created (site_key, status, created_at);

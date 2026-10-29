-- 平台代存 UGC：作品评论（#240 / docs/product-positioning.md §A.4）
--
-- 边界（三条红线，改动前先读）：
--   1. 平台对**来源站数据**只读——这张表存的是用户在我们客户端里写的内容，不是网站的内容；
--   2. 内容合规 / 实名 / 审核 / 留存的责任主体是**网站**，我们只提供存储与工具；
--   3. 站点隔离：site_key 一律取自登录态（app_user.site_key），**不接受请求参数**。
--
-- 为什么 work_id 用字符串而不是 work.id 外键：与 collection 同一口径——作品同步与用户内容
-- 不互相绑死（作品重导/清理时不该连带用户的评论）。代价是按 work_id 查要有索引，见下。
CREATE TABLE IF NOT EXISTS ugc_comment
(
    id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    site_key   VARCHAR(32)     NOT NULL COMMENT '站点键，取自登录用户的 app_user.site_key',
    work_id    VARCHAR(32)     NOT NULL COMMENT 'work.work_id（不建外键，同 collection）',
    user_id    BIGINT UNSIGNED NOT NULL COMMENT 'app_user.id',
    body       VARCHAR(1000)   NOT NULL COMMENT '纯文本，客户端渲染时按纯文本处理（不透传 HTML）',
    status     VARCHAR(16)     NOT NULL DEFAULT 'published'
        COMMENT 'published / hidden（站主或平台隐藏）/ deleted（作者删除，保留行以便追溯）',
    created_at DATETIME(3)     NOT NULL,
    updated_at DATETIME(3)     NOT NULL,
    PRIMARY KEY (id),
    -- 作品页按「最新在前」翻页：site + work + status 三列前缀，created_at 供排序
    KEY idx_ugc_work_created (site_key, work_id, status, created_at),
    -- 防滥用：按用户数「最近 N 分钟发了几条」
    KEY idx_ugc_user_created (site_key, user_id, created_at),
    CONSTRAINT fk_ugc_comment_user FOREIGN KEY (user_id) REFERENCES app_user (id)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT '作品评论（平台代存 UGC，B1 只做评论；点评/回复/举报后续）';

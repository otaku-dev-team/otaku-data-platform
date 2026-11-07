-- 资讯收藏（#377）
--
-- 为什么不复用 collection：collection.work_id 的语义是 work.work_id，且有
-- uk_collection_user_work；把 article_id 塞进同一列会让两类 id 混在一起，
-- 收藏页必须按类型分流，而资讯没有 want/watching/watched 三态（见
-- docs/article-favorite-proposal.md §2）。
--
-- 不建到 article 的外键：与 collection 对 work 的处理保持同一理由——
-- 内容同步与个人数据解耦。资讯被重新导入时不应被个人数据反向约束。
--
-- article_id 是 VARCHAR(32) 的不透明标识（V9），不是自增主键、也不是 source_id。
CREATE TABLE IF NOT EXISTS article_favorite
(
    id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    user_id    BIGINT UNSIGNED NOT NULL COMMENT 'app_user.id',
    article_id VARCHAR(32)     NOT NULL COMMENT 'article.article_id（不建外键，理由见文件头）',
    created_at DATETIME(3)     NOT NULL,
    updated_at DATETIME(3)     NOT NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uk_article_favorite_user_article (user_id, article_id),
    -- 列表按 updated_at DESC, article_id ASC 翻页；第二键保证同一毫秒写入时
    -- 顺序稳定，不会出现「翻页跳条」。
    KEY idx_article_favorite_user_updated (user_id, updated_at),
    CONSTRAINT fk_article_favorite_user FOREIGN KEY (user_id) REFERENCES app_user (id)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT '个人资讯收藏；取消收藏即删行';

-- 平台代存 UGC：点评（#240 B2c⑥，方案见 docs/ugc-review-proposal.md）
--
-- 口径（zm 2026-10-30 定）：
--   - 点评与评论**不打通**：点评是「打分 + 长评」，一人一条；评论是可回复的讨论流；
--   - 「看过才能评」**不强制**，由客户端引导；
--   - 独立表，不动阶段 2 已验收的 collection（收藏 = 状态，点评 = 评价，两件事）。
--
-- 一人一条靠 uk_review_user_work 保证：点评是「我对这部作品的评价」，天然唯一。
-- 想改就编辑，不想留就删；不做「多条短评堆在点评区」——那会把评价退化成第二个评论区。
CREATE TABLE IF NOT EXISTS ugc_review
(
    id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    site_key   VARCHAR(32)     NOT NULL COMMENT '站点键，取自作品来源所属站点',
    work_id    VARCHAR(32)     NOT NULL COMMENT 'work.work_id（不建外键，同 ugc_comment）',
    user_id    BIGINT UNSIGNED NOT NULL COMMENT 'app_user.id',
    rating     TINYINT UNSIGNED NULL COMMENT '1–10；NULL = 只写文字不打分',
    body       VARCHAR(5000)   NULL COMMENT '长评纯文本，不解析 HTML/Markdown；空 = 只打分',
    status     VARCHAR(16)     NOT NULL DEFAULT 'published'
        COMMENT 'published / pending（先审后发）/ hidden（站主隐藏）/ deleted（作者删除）',
    created_at DATETIME(3)     NOT NULL,
    updated_at DATETIME(3)     NOT NULL,
    edited_at  DATETIME(3)     NULL COMMENT '作者最后一次改内容的时间；NULL = 未编辑',
    PRIMARY KEY (id),
    -- 一人一条：重复提交返回 409，由业务层给出可读文案
    UNIQUE KEY uk_review_user_work (user_id, work_id),
    -- 作品页按「最新在前」翻页；summary 的聚合也走这个前缀
    KEY idx_review_work_created (site_key, work_id, status, created_at),
    CONSTRAINT fk_review_user FOREIGN KEY (user_id) REFERENCES app_user (id),
    -- 至少要有一样东西：只打分、只写评都行，两样都空不叫点评
    CONSTRAINT ck_review_not_empty CHECK (rating IS NOT NULL OR (body IS NOT NULL AND body <> ''))
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT '作品点评（打分 + 长评，一人一条）';

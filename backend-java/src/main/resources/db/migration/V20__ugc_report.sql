-- UGC 第三档：举报 + 先审后发（#240 B2b）
--
-- 产品口径（positioning §A.4）：内容合规的责任主体是网站，我们只提供工具。
-- 举报与「先审后发」就是两件最基本的工具：用户能举报、站主能选择发布策略。

-- 审核模式：post = 先发后审（默认，评论立刻可见）；pre = 先审后发（新评论 pending）
ALTER TABLE site
    ADD COLUMN ugc_moderation VARCHAR(8) NOT NULL DEFAULT 'post'
        COMMENT 'post=先发后审 / pre=先审后发；pre 时新评论落 pending，审核通过才对外可见';

CREATE TABLE IF NOT EXISTS ugc_report
(
    id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    site_key     VARCHAR(32)     NOT NULL COMMENT '取自举报人登录态，不接受请求参数',
    comment_id   BIGINT UNSIGNED NOT NULL,
    reporter_id  BIGINT UNSIGNED NOT NULL COMMENT 'app_user.id',
    reason       VARCHAR(200)    NOT NULL COMMENT '用户填写的理由（纯文本）',
    status       VARCHAR(16)     NOT NULL DEFAULT 'open' COMMENT 'open / resolved / dismissed',
    created_at   DATETIME(3)     NOT NULL,
    handled_at   DATETIME(3)     NULL,
    handled_by   VARCHAR(64)     NULL COMMENT '处理人 admin_id；审计另有明细',
    PRIMARY KEY (id),
    -- 同一个人对同一条评论只能举报一次：重复点「举报」不应制造一堆工单
    UNIQUE KEY uk_report_comment_reporter (comment_id, reporter_id),
    -- 后台队列：按站点 + 状态 + 时间倒序
    KEY idx_report_site_status (site_key, status, created_at),
    CONSTRAINT fk_ugc_report_comment FOREIGN KEY (comment_id) REFERENCES ugc_comment (id),
    CONSTRAINT fk_ugc_report_user FOREIGN KEY (reporter_id) REFERENCES app_user (id)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT '评论举报工单；处置动作写 console_audit';

-- 浏览行为（#401 拍板：客户端打点 POST /api/me/views，有界行）
--
-- 为什么是有界行而不是流水表：行数 = 用户数 × 看过的作品数，天然有上限；
-- 流水表能算停留时长与浏览路径，但现阶段用不上，却会按浏览量线性膨胀。
-- 聚合画像只需要「最近看过什么、看了几次」。
--
-- 保留期 90 天（#401 拍板），由 ViewCleanupJob 每天清 last_viewed_at 过期的行，
-- 所以 last_viewed_at 上要索引——清理是范围删除，没有索引就是全表扫。
CREATE TABLE user_work_view (
    user_id         BIGINT UNSIGNED NOT NULL,
    work_id         VARCHAR(32)     NOT NULL,
    first_viewed_at DATETIME(3)     NOT NULL,
    last_viewed_at  DATETIME(3)     NOT NULL,
    view_count      INT UNSIGNED    NOT NULL DEFAULT 1,
    PRIMARY KEY (user_id, work_id),
    KEY idx_user_work_view_last (last_viewed_at)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4;

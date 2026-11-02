-- 评分口径（Issue #383）：把评分人数 rating_count 入库存量，
--   使后端可按首站 MIN_RATING_COUNT=50 阈值决定「低票作品不展示评分、不进入评分排序」。
--
-- 来源：bangumi 镜像 rating.total，由 scripts/backfill_rating_count.py 批量回填。
-- 语义：NULL = 镜像未返回（404）或未回填；非 NULL 即真实评分人数（含 <50 的低票）。
--   后端判断「是否展示评分」用的是 rating_count >= 50，而不是 rating_value 是否为 NULL，
--   这样即使有评分值但样本过少，也不会拿低置信度的分数误导用户。
--
-- 幂等写法：生产库已手工加过该列（回填前急救），Flyway 再跑时不能因「列已存在」失败；
--   dev / CI 环境还没有这列，需要真正执行 ADD COLUMN。两种环境都要安全。

SET @col_exists := (
    SELECT COUNT(*)
      FROM information_schema.COLUMNS
     WHERE table_schema = DATABASE()
       AND table_name = 'work'
       AND column_name = 'rating_count'
);
SET @ddl := IF(@col_exists = 0,
    'ALTER TABLE work ADD COLUMN rating_count INT NULL COMMENT ''评分人数（bangumi 镜像 rating.total）；NULL=镜像未返回/未回填；后端按 MIN_RATING_COUNT=50 决定低票不展示评分、不进评分排序''',
    'SELECT 1');
PREPARE stmt FROM @ddl;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

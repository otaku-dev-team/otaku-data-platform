-- 评分口径（Issue #383）：低票作品「不进评分排序」。
--
-- 为什么不直接把 ORDER BY 改成 CASE 表达式：排序键一旦是表达式，idx_work_rating 就用不上了。
-- 2026-11-03 在生产数据（visible 18,676）上实测：
--   ORDER BY rating_value DESC, id DESC           → idx_work_rating 反向扫描，rows=20，9–14ms
--   ORDER BY (CASE ...) DESC, id DESC             → type=ALL，扫 163,229 行 + Using filesort，约 90–100ms
-- 所以把「排序用的评分」物化成一个生成列，配索引，排序回到有序扫描。
--
-- VIRTUAL 而不是 STORED：
--   - 虚拟列不重写表（ALTER 只是元数据 + 建索引），198k 行的库上不会长时间锁表；
--   - 二级索引仍然把算好的值存下来，排序按索引取值，不需要逐行计算；
--   - 写入零改动——生成列随 rating_value / rating_count 自动变，回填 rating_count 时自动重算。
--
-- 口径与 Java 侧 WorkService.MIN_RATING_COUNT 必须一致（有测试守着，见 RatingThresholdConsistencyTest）：
--   rating_count 为 NULL      → 按可信处理，用 rating_value（不动存量）
--   rating_count < 50         → 排序按 0（与「无评分」同档，沉底）
--   rating_count >= 50        → 用 rating_value
-- 注意 rating_value 为 NULL 时也落 0：DESC 排序下与低票同档，都排在所有正分之后。

SET @col_exists := (
    SELECT COUNT(*)
      FROM information_schema.COLUMNS
     WHERE table_schema = DATABASE()
       AND table_name = 'work'
       AND column_name = 'rating_sort'
);
SET @ddl := IF(@col_exists = 0,
    'ALTER TABLE work ADD COLUMN rating_sort DECIMAL(4,2) GENERATED ALWAYS AS (CASE WHEN rating_count IS NOT NULL AND rating_count < 50 THEN 0 ELSE COALESCE(rating_value, 0) END) VIRTUAL COMMENT ''排序用的评分（#383）：低票按 0；只用于 ORDER BY，不对外展示''',
    'SELECT 1');
PREPARE stmt FROM @ddl;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

-- 与 idx_work_rating 同构（列 + id 作次级键），只是主体换成了生效评分。
SET @idx_exists := (
    SELECT COUNT(*)
      FROM information_schema.STATISTICS
     WHERE table_schema = DATABASE()
       AND table_name = 'work'
       AND index_name = 'idx_work_rating_sort'
);
SET @ddl := IF(@idx_exists = 0,
    'ALTER TABLE work ADD INDEX idx_work_rating_sort (rating_sort, id)',
    'SELECT 1');
PREPARE stmt FROM @ddl;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

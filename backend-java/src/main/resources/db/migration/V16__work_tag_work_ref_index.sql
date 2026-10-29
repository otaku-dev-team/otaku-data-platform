-- 导入性能：work_tag 按 work_ref 删除缺索引（Issue #270）
--
-- 症状：导入一部要 385–650 ms，其中 `DELETE FROM work_tag WHERE work_ref = ?` 占 409 ms。
-- 根因：work_tag 的主键是 (tag, work_ref)，所有索引都以 tag 打头，
-- 按 work_ref 删除只能全表扫（实测 EXPLAIN type=ALL，扫描 409,398 行）。
-- 每次导入都会重写标签（work_tag 与 work 行同事务维护），于是每部作品都付一次全表扫描。
--
-- 修法：补一个以 work_ref 打头的索引。DELETE 变成范围扫描（2–3 行），实测降到 1 ms 内。
-- 代价：520k 行的二级索引约 15 MB；work_tag 只在导入时写入，读路径按 tag 过滤不受影响。
--
-- 幂等写法：线上已手工加过该索引（发版前急救），Flyway 再跑时不能因「索引已存在」失败。

SET @idx_exists := (
    SELECT COUNT(*)
      FROM information_schema.statistics
     WHERE table_schema = DATABASE()
       AND table_name = 'work_tag'
       AND index_name = 'idx_work_tag_ref'
);
SET @ddl := IF(@idx_exists = 0,
    'ALTER TABLE work_tag ADD KEY idx_work_tag_ref (work_ref)',
    'SELECT 1');
PREPARE stmt FROM @ddl;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

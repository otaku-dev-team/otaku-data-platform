-- 标签筛选：把 work.tags 这个 JSON 数组复制成一张可索引的关联表。
--
-- 为什么不能只靠 JSON 列：2026-10-22 在 55.6 万条上实测了三条路，只有关联表可用。
--   1) JSON_CONTAINS + MySQL 多值索引：优化器**不走**索引（EXPLAIN key=NULL），
--      全表扫 743ms，建了索引反而劣化到 1435ms；
--   2) MEMBER OF：走了多值索引（ref / idx_tags_mv），但 1285ms —— 更慢。
--      原因是高频标签占比高（「科幻」占 20% 行），索引对高频值天然无效；
--   3) 本表 + (tag, rating_value, work_ref)：计数 19.5ms、筛选+评分排序首页 35ms、
--      深页 50ms（同量级数据）。
--
-- 为什么把 rating_value / release_year / work_type 冗余进这张表：列表的三种排序与类型过滤
-- 都要和标签组合。只存 work_ref 的话，按评分排要先 JOIN 再对十几万行 filesort（实测 772ms）；
-- 组合类型过滤更糟：55.6 万条实测 `COUNT(*) ... JOIN work` 要 46,000 次回表、296ms，
-- 而纯索引扫描只要个位数毫秒。冗余的代价是评分/年份/类型变化时要同步更新，
-- 而写入路径本来就会重写整组标签（见 WorkRepository#replaceTags），成本可接受。
--
-- 为什么 tag 用 VARCHAR(64) 而不是更长：来源侧每条最多 5 个标签、长度都很短
-- （实测最长 12 字）。64 足够，索引也更小；回填时用 LEFT(...,64) 兜底，
-- 极少数超长标签会被截断，截断后同名会合并——宁可少一个标签，不要让迁移失败。
--
-- 为什么没有外键：work 行在本项目里永不删除（铁律 3：抓不到 ≠ 已删除），
-- 外键只会给批量导入增加检查开销。删除路径不存在，也就没有悬空引用。
CREATE TABLE IF NOT EXISTS work_tag
(
    work_ref     BIGINT UNSIGNED   NOT NULL COMMENT 'work.id，不是 work_id',
    tag          VARCHAR(64)       NOT NULL,
    work_type    VARCHAR(16)       NOT NULL COMMENT '冗余自 work.work_type，供类型+标签组合走索引',
    rating_value DECIMAL(4, 2)     NULL COMMENT '冗余自 work.rating_value，供标签内按评分排序',
    release_year SMALLINT UNSIGNED NULL COMMENT '冗余自 work.release_year，供标签内按年份排序',
    PRIMARY KEY (tag, work_ref),
    KEY idx_work_tag_rating (tag, rating_value, work_ref),
    KEY idx_work_tag_year (tag, release_year, work_ref),
    KEY idx_work_tag_type (tag, work_type, rating_value, work_ref)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT '标签 -> 作品的反查表，由导入链路维护';

-- 存量回填：57 万量级约几十秒，一次性。
-- INSERT IGNORE 兜住两类重复：同一作品标签重复、以及超长标签被截断后同名。
INSERT IGNORE INTO work_tag (work_ref, tag, work_type, rating_value, release_year)
SELECT w.id, LEFT(jt.tag, 64), w.work_type, w.rating_value, w.release_year
FROM work w
         JOIN JSON_TABLE(w.tags, '$[*]' COLUMNS (tag VARCHAR(255) PATH '$')) jt ON TRUE
WHERE w.tags IS NOT NULL
  AND JSON_LENGTH(w.tags) > 0
  AND jt.tag IS NOT NULL
  AND jt.tag <> '';

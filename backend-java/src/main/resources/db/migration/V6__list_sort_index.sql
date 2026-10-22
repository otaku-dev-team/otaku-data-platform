-- 列表排序：支持 sort=rating / sort=year（默认仍是 id ASC，行为不变）。
--
-- 为什么需要索引：列表接口每次都先 COUNT 再取页，取页本身便宜（有 LIMIT 可提前终止），
-- 但排序若无索引可用，MySQL 必须对全表 filesort。2026-10-22 在 55.6 万条合成数据上实测：
--   ORDER BY rating_value DESC LIMIT 50   无索引 366ms → 有索引 0.4ms（反向索引扫描）
--   标签筛选 + 评分排序（join work）       901ms → 55ms
--
-- 为什么次级键是 id 且与主键同向 DESC：
--   分页必须稳定，同分记录要有唯一兜底；两列都 DESC 才能命中「Backward index scan」，
--   若是 (rating DESC, id ASC) 这种混合方向，MySQL 仍要 filesort，索引就白建了。
--
-- 为什么 NULL 不用特殊处理：MySQL 升序时 NULL 排最前，DESC 排序自然把
--   无评分 / 无年份的作品排到末尾——符合「没有数据的沉底」这一预期。
--
-- 注：JSON_OVERLAPS（详情页同标签推荐用到）要求 MySQL ≥ 8.0.17；
--     本项目 compose 固定 mysql:8.0（实测 8.0.46），满足。
ALTER TABLE work
    ADD INDEX idx_work_rating (rating_value, id),
    ADD INDEX idx_work_year (release_year, id);

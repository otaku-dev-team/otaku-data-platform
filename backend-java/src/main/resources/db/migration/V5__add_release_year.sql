-- 年份：来源站 `year` 字段，此前一直未落库。
--
-- 数据可用性：2026-10-22 实测 anime 800 条均匀抽样，非空 95.9%（767/800）。
-- 旧文档「约 98.5% 为空」是 2026-10-20 的记录，已被推翻，见 docs/站点能力差距清单.md。
--
-- 为什么是 SMALLINT UNSIGNED 而不是 YEAR 类型：
--   MySQL 的 YEAR 只接受 1901–2155 且 0000 是合法值（表示"零年"），
--   与「NULL = 来源未提供」的语义冲突——一旦存进 0000 就再也区分不出空缺。
--   这里要的是"要么是真实年份，要么是 NULL"，用整数更直白。
--
-- 为什么可空而不是默认 0：0 会被当成"公元 0 年"参与筛选与排序，
--   与契约「NULL 表示来源没有，不是 0」的既有约定（见 rating_value）保持一致。
ALTER TABLE work
    ADD COLUMN release_year SMALLINT UNSIGNED NULL
        COMMENT '来源站年份原值；NULL 表示来源未提供，不是 0'
        AFTER summary;

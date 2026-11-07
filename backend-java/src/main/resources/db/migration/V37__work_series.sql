-- 系列（#411 / docs/relation-algorithm.md §5.4）
--
-- 数据集 v3 早就有 series(series_key, name) 与 works.series_key，但后端从没消费过：
-- 导入载荷里没有这个字段，v3 的 series 在提交那一步被静默丢掉（不报错、不落库）。
-- 这里补上存储；反查靠 work.series_key 上的索引。
--
-- 为什么 series_key 直接放 work、不建 work↔series 关系表：
--   一部作品只属于一个系列（数据集即如此），一对多不需要中间表；
--   关系表会让「同系列的兄弟作品」多一次 join，而这是唯一一种访问方式。
--
-- 为什么 name 单独一张 series 表：
--   名称只在一个系列里存在一份。放 work 上等于每行冗余一份，改名要扫全表；
--   放这里还能容纳「作品还没导入但系列已建」的中间态（导入先 upsert 系列再写作品）。
--
-- 长度 64 / 255 与数据集侧 series_key TEXT、name TEXT 的实测取值对齐：
-- 现有 series_key 是来源站 id（数字串），name 最长几十字；64/255 留了足够余量。

ALTER TABLE work
    ADD COLUMN series_key VARCHAR(64) NULL
        COMMENT '系列键（数据集 v3 series.series_key）；NULL = 不属于任何系列',
    ADD KEY idx_work_series (series_key, release_year);

CREATE TABLE IF NOT EXISTS series
(
    series_key VARCHAR(64)  NOT NULL COMMENT '数据集 v3 的 series.series_key，来源站自身 id',
    name       VARCHAR(255) NULL COMMENT '系列名；数据集没给就留 NULL，不拿 key 冒充',
    created_at DATETIME(3)  NOT NULL,
    updated_at DATETIME(3)  NOT NULL,
    PRIMARY KEY (series_key)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT '系列清单（#411）；作品侧靠 work.series_key 反查';

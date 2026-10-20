-- 第一阶段表结构：作品 + 导入批次
-- 与 docs/stage1-minimal-contract.md 第 2 节字段集一致。
-- 约定：时间统一存 UTC 的 DATETIME(3)；空值一律 NULL，不用 '' / 0 等伪值。

CREATE TABLE IF NOT EXISTS work
(
    id               BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '物理主键，不对外暴露',
    work_id          VARCHAR(32)     NOT NULL COMMENT '平台内部标识，对外不透明，创建后永不改变',
    work_type        VARCHAR(16)     NOT NULL COMMENT 'anime / comic / game / novel',
    title            VARCHAR(500)    NOT NULL COMMENT '来源标题原文，不做跨类型转换',
    summary          TEXT            NULL COMMENT '来源简介，最长 7225 字，不截断；NULL 表示来源没有',
    cover_source_url VARCHAR(1024)   NULL COMMENT '来源站封面绝对地址，仅内部使用，不出口',
    cover_cache_key  VARCHAR(128)    NULL COMMENT '本地缓存文件名 = sha256(来源地址) + 扩展名',
    cover_cached_at  DATETIME(3)     NULL COMMENT '本地缓存落盘时间',
    tags             JSON            NULL COMMENT 'NULL=来源未提供(不覆盖)；[]=明确无标签(可清空)',
    rating_value     DECIMAL(4, 2)   NULL COMMENT '来源评分原值；NULL 表示无评分，不是 0 分',
    rating_scale     VARCHAR(16)     NULL COMMENT '评分尺度，当前为 0-10',
    rating_source    VARCHAR(64)     NULL COMMENT '评分来源标识',
    source           VARCHAR(64)     NOT NULL COMMENT '接入方标识，第一阶段固定 otaku_site',
    source_id        VARCHAR(128)    NOT NULL COMMENT '来源站作品 ID，字符串存储避免数值歧义',
    created_at       DATETIME(3)     NOT NULL,
    updated_at       DATETIME(3)     NOT NULL COMMENT '仅在内容真的变化时推进',
    PRIMARY KEY (id),
    UNIQUE KEY uk_work_source (source, source_id),
    UNIQUE KEY uk_work_id (work_id),
    KEY idx_work_type_id (work_type, id),
    KEY idx_work_title (title)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT '作品元数据，只有 Java 写入';

CREATE TABLE IF NOT EXISTS import_batch
(
    batch_id     VARCHAR(128) NOT NULL COMMENT '幂等键，来自同步作业',
    source       VARCHAR(64)  NOT NULL,
    request_hash CHAR(64)     NOT NULL COMMENT 'items 的 SHA-256，用于识别同 batch_id 不同内容',
    inserted     INT          NOT NULL DEFAULT 0,
    updated      INT          NOT NULL DEFAULT 0,
    unchanged    INT          NOT NULL DEFAULT 0,
    rejected     INT          NOT NULL DEFAULT 0,
    errors       JSON         NULL COMMENT '逐条失败明细与提示项',
    started_at   DATETIME(3)  NOT NULL,
    finished_at  DATETIME(3)  NULL,
    PRIMARY KEY (batch_id)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT '导入批次追踪；不做短路回放，理由见 ImportBatchRepository 注释';

-- 新番档期（每日新番）
--
-- 数据来自来源站 GET /api/schedule（1500 条，按周一…周日 + 待定分组），
-- 探测结论见 docs/站点能力差距清单.md 第 3.2 节。与 work 是两张独立的表：
-- 档期条目不一定是作品（站点自己的排播数据），关联是尽力而为的——
-- content_id 命中 work(source='otaku_site', source_id=content_id) 时回填 work_id，
-- 不命中就留 NULL，接口层据此决定"能不能跳本地详情"。
--
-- 版本号说明：V7 预留给标签筛选（pyxz0），本表取 V8，已在 PR #86 留言同步。
--
-- 字段口径（与站点 JSON 对齐，命名按本库习惯调整）：
-- - weekday 为 1..7（周一..周日），NULL = 待定；不存 0，避免"周日还是待定"的歧义
-- - work_tags 站点给的是斜杠分隔字符串（"战斗/群像/英雄剧"），导入时转成 JSON 数组，
--   与 work.tags 同构；转不出东西时存 NULL（未提供），不存空数组
-- - platforms 站点给 [{name,url}] 对象数组，用 **TEXT 存紧凑 JSON 文本**而不是
--   JSON 列：MySQL 的 JSON 列会按 key 排序存储对象（写进去 name,url，读出来
--   url,name），字符串比较永远不相等，"重跑应全部 unchanged"直接挂。
--   数组列（work_tags）不受此影响，MySQL 只重排对象键，所以那里仍用 JSON 列。
-- - image_url 是 B 站外链且未本地化：只存原文，**不本地化、不做强依赖**，
--   加载失败由客户端降级占位图
-- - source_updated_at 取站点的 last_synced_at，仅作记录，不参与幂等判定

CREATE TABLE IF NOT EXISTS schedule
(
    id                BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '物理主键，不对外暴露',
    schedule_id       VARCHAR(32)     NOT NULL COMMENT '平台内部标识，对外不透明，创建后永不改变',
    source            VARCHAR(64)     NOT NULL COMMENT '接入方标识，当前固定 otaku_site',
    source_id         VARCHAR(128)    NOT NULL COMMENT '站点档期条目 ID，字符串存储避免数值歧义',
    season_code       VARCHAR(16)     NULL COMMENT '季度编码，如 202504；NULL 表示站点未归类',
    title_main        VARCHAR(500)    NOT NULL COMMENT '站点主标题（通常为中文）',
    title_cn          VARCHAR(500)    NULL COMMENT '站点中文标题',
    title_jp          VARCHAR(500)    NULL COMMENT '站点日文标题',
    weekday           TINYINT         NULL COMMENT '1..7 周一..周日；NULL=待定（不用 0）',
    broadcast_time    VARCHAR(16)     NULL COMMENT '放送时刻，如 22:00；站点常为 null',
    broadcast_note    VARCHAR(255)    NULL COMMENT '放送备注原文，如「1/13周一深夜；(全12话)」',
    work_type         VARCHAR(64)     NULL COMMENT '站点作品类型描述，如「游戏 改编动画」',
    work_tags         JSON            NULL COMMENT 'NULL=未提供；[]=明确无标签（由斜杠字符串转换）',
    image_url         VARCHAR(1024)   NULL COMMENT 'B 站外链封面，未本地化，不强依赖',
    platforms         TEXT            NULL COMMENT '[{name,url}] 紧凑 JSON 文本；不用 JSON 列（MySQL 会按 key 重排，详见文件头）',
    source_url        VARCHAR(1024)   NULL COMMENT '来源页（yuc.wiki）',
    content_id        VARCHAR(128)    NULL COMMENT '站点作品 ID，用于关联本地作品',
    work_id           VARCHAR(32)     NULL COMMENT '命中本地作品时回填 work_id；NULL=未命中',
    source_updated_at DATETIME(3)     NULL COMMENT '站点 last_synced_at，仅记录',
    created_at        DATETIME(3)     NOT NULL,
    updated_at        DATETIME(3)     NOT NULL COMMENT '仅在内容真的变化时推进',
    PRIMARY KEY (id),
    UNIQUE KEY uk_schedule_source (source, source_id),
    UNIQUE KEY uk_schedule_id (schedule_id),
    -- 查询形态只有一种：按星期分组列条目。season 单独建索引是因为"看某个季度"
    -- 是第二入口（切换季度时要按 season + weekday 取）。
    KEY idx_schedule_weekday (weekday, id),
    KEY idx_schedule_season_weekday (season_code, weekday, id)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT '新番档期；只有 Java 写入';

-- 最新资讯
--
-- 数据来自来源站 /articles 与 /articles/{id}（**只有 HTML**，
-- /api/articles 返 404，见 docs/站点能力差距清单.md）。字段按实测页面结构落库：
--   列表页 article-meta 的分类徽章 / 时间、article-card-title/summary、article-card-thumb
--   详情页 article-title、article-byline（来源 + 发布时间）、article-body、
--           article-source-link（原文链接）、article-source-origin（来源名）
--
-- 版本号说明：V7 标签筛选已合（#104）、V8 是新番档期（#102），
-- 本表取 V9。**必须等 #102 合入后再合本迁移** —— Flyway outOfOrder=false，
-- 先合 V9 再补 V8 会直接启动失败。
--
-- 字段口径：
-- - summary/body 是**纯文本**，不是 HTML：正文里 <p> 与 <figure> 混排，
--   客户端要渲染就得引 HTML 解析依赖；资讯的价值在文字本身，先存纯文本，
--   图片只留首图作 cover_url。正文归一成一行一段。
-- - cover_url 拼成**来源站绝对地址**（列表页给的是 /article-images/xxx.jpg 相对路径）。
--   与 work 的封面不同：work 走本地封面代理（cover_source_url + cover_cached_key），
--   本表不做本地化——资讯首图只是配图，加载失败由客户端降级占位图。
-- - source_url 是**原文链接**（如 ln-news.com）。存它是为了让用户能跳回原文，
--   对应项目章程 G3「用户不被困在平台内」。不给原文链接的资讯不给跳。
-- - tags 是 JSON 数组，与 work.tags 同构：站点两处都指向 /contents?tag=xxx，
--   是同一套标签体系。NULL=未提供，[]=明确无标签。
-- - related_work_ids 是详情页「关联作品」区给的**站点作品 id 原文**，
--   不回填本地 work_id：那区块是编辑推荐的相关作品，不等于本文主角，
--   回填了反而会让客户端给出「本文对应这部作品」的错误跳转。
--   存下来是为了将来做关联时不必重新抓页面。
-- - published_at 是资讯的排序依据（新的在前），没有它只能按 id 排。

CREATE TABLE IF NOT EXISTS article
(
    id                BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '物理主键，不对外暴露',
    article_id        VARCHAR(32)     NOT NULL COMMENT '平台内部标识，对外不透明，创建后永不改变',
    source            VARCHAR(64)     NOT NULL COMMENT '接入方标识，当前固定 otaku_site',
    source_id         VARCHAR(128)    NOT NULL COMMENT '站点资讯 ID，字符串存储避免数值歧义',
    title             VARCHAR(500)    NOT NULL COMMENT '资讯标题',
    summary           TEXT            NULL COMMENT '列表页摘要；NULL=来源未提供',
    body              MEDIUMTEXT      NULL COMMENT '详情页正文纯文本，一行一段；NULL=未抓正文',
    category          VARCHAR(64)     NULL COMMENT '分类徽章原文，如 漫画/动画/游戏/轻小说/综合动态',
    published_at      DATETIME(3)     NULL COMMENT '发布时间；NULL=来源未提供，此时按 id 兜底排序',
    source_name       VARCHAR(255)    NULL COMMENT '来源站点名，如 ラノベニュースオンライン',
    source_url        VARCHAR(1024)   NULL COMMENT '原文链接，供客户端跳回来源站（章程 G3）',
    cover_url         VARCHAR(1024)   NULL COMMENT '首图（来源站绝对地址），未本地化，不强依赖',
    tags              JSON            NULL COMMENT 'NULL=未提供；[]=明确无标签（与 work.tags 同构）',
    related_work_ids  JSON            NULL COMMENT '来源站关联作品 id 原文；不回填本地 work_id，理由见文件头',
    created_at        DATETIME(3)     NOT NULL,
    updated_at        DATETIME(3)     NOT NULL COMMENT '仅在内容真的变化时推进',
    PRIMARY KEY (id),
    UNIQUE KEY uk_article_source (source, source_id),
    UNIQUE KEY uk_article_id (article_id),
    -- 列表只有一个形态：按发布时间倒序。id 作次级键，否则同一秒的多条
    -- 顺序由存储引擎决定，翻页时会看到重复或漏条。
    KEY idx_article_published (published_at, id),
    -- 分类筛选是第二入口（站点自己也有 /articles?category=）。
    KEY idx_article_category_published (category, published_at, id)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT '最新资讯；只有 Java 写入';
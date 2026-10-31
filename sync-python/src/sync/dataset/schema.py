"""标准同步数据集（sync-dataset v1）的物理结构与契约。

## 为什么需要这一层

源库的表结构是客户的，我们改不了；导入契约是我们的，不能跟着客户漂。
中间必须有一个**我们自己定义、自己版本化**的格式，把耦合钉死在一处：

    [客户源库] --(映射配置 + 导出器)--> [sync-dataset] --(导入器)--> [我们的后端]

- 云端只认这个格式，与任何源库的表名/列名/引擎无关；
- 客户改表名、加列、换数据库，只影响「映射配置」这一个文件，不动代码；
- 每站独有的富字段进 `works.extra_json` / `work_facts`，**绝不为某个客户新建列**
  —— 每接一个站就改一次表，那等于耦合没解决，只是换了个地方疼。

## 规范化而非宽表

`works` 不存 tags 数组，标签放 `work_tags` 关联表。理由：标签/Staff/声优/制作
都是天然的一对多，宽表会让「同一批数据」有两处表示，早晚不一致。聚合到导入
接口的 `tags: []` 是导入器的事，不是存储的事。

## 与契约的关系

`works` 的前 9 列与 `docs/data-contract.md` 的 ImportItem 9 字段一一对应，
`extra_json` 之后的是「契约暂未收、但数据已经拿到」的富字段。后端不知道这些
字段也不会错——它们停在数据集里，等契约扩容时直接取用，不用再回源一次。
"""

from __future__ import annotations

#: 数据集格式版本。结构变更（增删列/改语义）必须递增，导入器据此拒收未知版本。
#:
#: v1 → v2（2026-10-28）：新增 `people` 表（人物 / 公司实体），并把 `work_credits`
#: 的取数从「整表照搬」改成「按 role 白名单过滤」。加表本身是增量变更，但同一份
#: 映射文件里 credits 的口径也变了（从 40.8 万条变 18.3 万条），读方不能默认
#: 「v1 的 credits 与 v2 的 credits 是同一批数据」，所以升版本而不是悄悄扩表。
#:
#: v2 → v3（2026-11-01）：`people.source_id` 与 `work_credits.person_ref` /
#: `work_cast.person_ref` 的取值规则全换，从「网站自增 id 与 Bangumi 人物 id 混用」
#: 改成统一的前缀键（`bgm:` 强关联 / `pname:` `cname:` 弱关联，见 §7 of
#: docs/person-id-unification.md）。**列不变、语义全变**——v2 的 `source_id` 是
#: 网站自增 id，v3 的同名列是 `bgm:123` 这样的键，读方按 v2 理解会静默拿错人，
#: 所以必须升版本，且不能靠「列还在」判断兼容。
DATASET_VERSION = "3"

#: 导出器自身版本，写进 meta 便于排查「哪个版本导出的坏数据」。
EXPORTER_VERSION = "1.0.0"

#: meta 表的键。用 key/value 而非固定列，方便以后加不破坏旧读方的元信息。
META_SCHEMA_VERSION = "dataset_version"
META_SOURCE_ID = "source_id"
META_GENERATED_AT = "generated_at"
META_SOURCE_FINGERPRINT = "source_fingerprint"
META_ROW_COUNTS = "row_counts_json"
META_DEGRADED = "degraded_json"
META_EXPORTER_VERSION = "exporter_version"

#: 源侧「公开内容」白名单。映射配置只能引用这些表，引用其它一律拒绝构建。
#: 这不是靠自觉——导出器只按映射读，映射里有越界表就直接失败退出，
#: 防止某天有人顺手把 users 加进映射。
PUBLIC_SOURCE_TABLES = frozenset({
    "contents",
    "content_facts",
    "content_credits",
    "content_cast",
    "content_studios",
    "content_entity_links",
    "content_relations",
    "content_tags",
    "entities",
    "series",
    "tags",
    "articles",
    "article_tags",
    "article_content_links",
    "anime_schedules",
})

#: 明确禁止出现的表名片段。命中即拒绝导出，宁可停下也不「大概没问题」。
FORBIDDEN_TABLE_HINTS = (
    "user", "account", "session", "token", "password", "invite",
    "favorite", "history", "submission", "persona", "test_",
    "job", "log", "poster",
)

DDL = """
PRAGMA journal_mode = OFF;
PRAGMA synchronous = OFF;

CREATE TABLE meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- 作品。前 9 列 = ImportItem 9 字段，之后是富字段。
CREATE TABLE works (
    source_id         TEXT PRIMARY KEY,
    work_type         TEXT,
    title             TEXT NOT NULL,
    summary           TEXT,
    cover_url         TEXT,
    release_year      INTEGER,
    rating_value      REAL,
    rating_scale      TEXT,
    source_url        TEXT,
    -- 以下富字段：契约尚未收，但数据已到手，留在数据集里等扩容
    title_original    TEXT,
    summary_original  TEXT,
    aliases_json      TEXT,
    rating_count      INTEGER,
    media             TEXT,
    episodes          INTEGER,
    source_material   TEXT,
    series_key        TEXT,
    source_updated_at TEXT,
    extra_json        TEXT
);
CREATE INDEX ix_works_type ON works(work_type);
CREATE INDEX ix_works_year ON works(release_year);

-- 标签（多对多）
CREATE TABLE work_tags (
    source_id TEXT NOT NULL,
    name      TEXT NOT NULL,
    PRIMARY KEY (source_id, name)
);

-- 客观信息键值：放送星期 / 放送结束 / 官网 / 企画 / 别名 …（值域不固定）
CREATE TABLE work_facts (
    source_id TEXT NOT NULL,
    key       TEXT NOT NULL,
    value     TEXT NOT NULL,
    PRIMARY KEY (source_id, key)
);

-- 人物 / 公司实体。`work_credits.person_ref` 与 `work_cast.person_ref` 指向这里的 source_id。
--
-- source_id 是**前缀键**，一张表装两类身份（v3 起）：
--   bgm:<Bangumi 人物 id>  强关联：声优、长尾 staff、以及补到 id 的主创
--   pname:<归一化人名>      弱关联：只有名字的主创（infobox 文本来源）
--   cname:<归一化公司名>    弱关联：全部制作公司（公司永远没有 Bangumi 人物 id）
-- 前缀不只是命名习惯——读方据此判断「能不能断言这是同一个人」：
-- bgm: 可以跨源合并，pname:/cname: 只能站内聚合作品列表。
-- 人名与公司前缀不同，同名的人和公司不会撞主键。
CREATE TABLE people (
    source_id         TEXT PRIMARY KEY,
    name              TEXT NOT NULL,
    entity_type       TEXT,
    bangumi_person_id TEXT
);

-- 制作人员
CREATE TABLE work_credits (
    source_id  TEXT NOT NULL,
    role       TEXT NOT NULL,
    name       TEXT NOT NULL,
    person_ref TEXT,          -- v3：bgm:/pname: 键，不再留空
    tier       TEXT,
    sort_order INTEGER
);
CREATE INDEX ix_credits_src ON work_credits(source_id);

-- 角色 · 声优
CREATE TABLE work_cast (
    source_id  TEXT NOT NULL,
    character  TEXT NOT NULL,
    actor      TEXT NOT NULL,
    person_ref TEXT,          -- v3：bgm:/pname: 键，不再留空
    relation   TEXT,
    sort_order INTEGER
);
CREATE INDEX ix_cast_src ON work_cast(source_id);

-- 制作公司
CREATE TABLE work_studios (
    source_id TEXT NOT NULL,
    name      TEXT NOT NULL,
    PRIMARY KEY (source_id, name)
);

-- 作品关系（续作 / 衍生作 / 同系列）
CREATE TABLE work_relations (
    source_id         TEXT NOT NULL,
    related_source_id TEXT NOT NULL,
    relation          TEXT,
    PRIMARY KEY (source_id, related_source_id)
);

-- 系列
CREATE TABLE series (
    series_key TEXT PRIMARY KEY,
    name       TEXT
);

-- 标签词表
CREATE TABLE tags (
    name TEXT PRIMARY KEY,
    kind TEXT
);

-- 资讯
CREATE TABLE articles (
    source_id         TEXT PRIMARY KEY,
    title             TEXT NOT NULL,
    summary           TEXT,
    body              TEXT,
    category          TEXT,
    subcategory       TEXT,
    event_type        TEXT,
    published_at      TEXT,
    source_name       TEXT,
    source_url        TEXT,
    cover_url         TEXT,
    is_adult          INTEGER,
    source_updated_at TEXT,
    extra_json        TEXT
);
CREATE INDEX ix_articles_pub ON articles(published_at);

-- 资讯 ↔ 作品
CREATE TABLE article_links (
    article_source_id TEXT NOT NULL,
    work_source_id    TEXT NOT NULL,
    PRIMARY KEY (article_source_id, work_source_id)
);

-- 新番档期
CREATE TABLE schedules (
    source_id         TEXT PRIMARY KEY,
    season_code       TEXT,
    title_main        TEXT,
    title_cn          TEXT,
    title_jp          TEXT,
    weekday           INTEGER,
    broadcast_time    TEXT,
    broadcast_note    TEXT,
    air_date          TEXT,
    box_office        TEXT,
    work_type         TEXT,
    work_tags_json    TEXT,
    image_url         TEXT,
    platforms_json    TEXT,
    source_url        TEXT,
    content_source_id TEXT,
    source_updated_at TEXT
);
CREATE INDEX ix_schedules_season ON schedules(season_code);
"""

#: 数据集内所有表，顺序即导出顺序（父表先于子表，便于调试时用 sqlite 手查）。
DATASET_TABLES = (
    "works", "work_tags", "work_facts", "people", "work_credits", "work_cast",
    "work_studios", "work_relations", "series", "tags",
    "articles", "article_links", "schedules",
)


def is_forbidden_source_table(name: str) -> bool:
    """源表名是否命中禁区（用户/凭据/收藏/日志类）。

    白名单优先：`PUBLIC_SOURCE_TABLES` 里的表即便命中片段也放行
    （例如 `content_tags` 含 "tag"、`anime_schedules` 无敏感词）。
    """
    lowered = name.lower()
    if lowered in PUBLIC_SOURCE_TABLES:
        return False
    return any(hint in lowered for hint in FORBIDDEN_TABLE_HINTS)

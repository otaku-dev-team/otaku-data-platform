-- 档 B 详情的三块关系数据（Issue #255，契约 Work.staff / characters / studios）
--   - 三张 work_* 表的外键是 work.id（内部主键），不是 source_id；
--   - person_id 存来源侧实体标识（字符串），允许为空：Staff 侧实测 0% 有值、声优侧 100%；
--   - character_type 实测 84% 为空（来源不分主配角），NULL 是常态；
--   - sort_order 保留来源顺序（数据集里的数组顺序），详情按它 + id 稳定排序；
--   - 整体替换语义由应用层（先删后插，同一事务）保证，这里只提供索引与外键。
--
-- people 表本期**只建表、不导入**（B2 人物页才用，契约也还没有 people 载荷）。

CREATE TABLE IF NOT EXISTS work_staff
(
    id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    work_ref   BIGINT UNSIGNED NOT NULL COMMENT 'work.id（内部主键）',
    role       VARCHAR(64)     NOT NULL COMMENT '职位，来源原值，不做归一',
    name       VARCHAR(200)    NOT NULL COMMENT '人名，来源原值',
    person_id  VARCHAR(64)     NULL COMMENT '人物实体标识；Staff 侧实测 0% 有值',
    sort_order INT             NOT NULL DEFAULT 0 COMMENT '来源数组顺序',
    PRIMARY KEY (id),
    KEY idx_work_staff_ref (work_ref, sort_order),
    CONSTRAINT fk_work_staff_work FOREIGN KEY (work_ref) REFERENCES work (id) ON DELETE CASCADE
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT '制作人员（档 B）';

CREATE TABLE IF NOT EXISTS work_characters
(
    id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    work_ref       BIGINT UNSIGNED NOT NULL COMMENT 'work.id（内部主键）',
    name           VARCHAR(200)    NOT NULL COMMENT '角色名',
    actor          VARCHAR(200)    NOT NULL COMMENT '声优名，来源原值',
    character_type VARCHAR(16)     NULL COMMENT '角色类型原值；84% 为空，NULL 是常态',
    person_id      VARCHAR(64)     NULL COMMENT '声优的人物实体标识，实测 100% 有值',
    sort_order     INT             NOT NULL DEFAULT 0 COMMENT '来源数组顺序',
    PRIMARY KEY (id),
    KEY idx_work_characters_ref (work_ref, sort_order),
    CONSTRAINT fk_work_characters_work FOREIGN KEY (work_ref) REFERENCES work (id) ON DELETE CASCADE
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT '角色与声优（档 B）';

CREATE TABLE IF NOT EXISTS work_studios
(
    id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    work_ref   BIGINT UNSIGNED NOT NULL COMMENT 'work.id（内部主键）',
    name       VARCHAR(200)    NOT NULL COMMENT '制作公司名，来源原值',
    sort_order INT             NOT NULL DEFAULT 0 COMMENT '来源数组顺序',
    PRIMARY KEY (id),
    KEY idx_work_studios_ref (work_ref, sort_order),
    CONSTRAINT fk_work_studios_work FOREIGN KEY (work_ref) REFERENCES work (id) ON DELETE CASCADE
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT '制作公司（档 B）';

-- 本期只建表：契约还没有 people 载荷，人物页（B2）落地时再接入。
CREATE TABLE IF NOT EXISTS people
(
    id               BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    source           VARCHAR(64)     NOT NULL COMMENT '来源标识，如 otaku_site',
    source_id        VARCHAR(128)    NOT NULL COMMENT '来源侧人物主键',
    name             VARCHAR(200)    NOT NULL,
    entity_type      VARCHAR(32)     NULL COMMENT '来源侧实体类型原值',
    bangumi_person_id VARCHAR(64)    NULL COMMENT '跨源映射预留（Bangumi 侧 id）',
    PRIMARY KEY (id),
    UNIQUE KEY uk_people_source (source, source_id)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT '人物实体（B2 人物页用，本期不导入）';

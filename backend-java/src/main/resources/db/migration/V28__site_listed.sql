-- 只显示首站收录的作品（#370）：把「收录范围」落成一个白名单表 + 两列标记。
--
-- 背景：昨晚（11-01）线上是应急，用 `deleted_at = '2099-01-01'` 当"隐藏"用了：
-- 18.3 万行被打了这个哨兵时间，列表从 19 万降到 2.5 万。那是**借位的**做法——
-- deleted_at 的语义是「来源侧删了」（#249），不是「我们不想显示」。借位的代价：
--   ① 任何按 deleted_at 判"存在/已删"的代码都会以为这 18 万部真没了；
--   ② 正规化时无法与真正的软删区分，只能靠哨兵值反查；
--   ③ 导入的 upsert 会把 deleted_at 置空（#249 的规则），下一次导入就全复活。
-- 所以这一版把「显示与否」拆成独立列 site_listed，并把哨兵时间**全部清掉**。
--
-- 口径（zm 2026-11-01 定）：**库里存全量，app 只显示首站收录的**。
-- 白名单来自首站 `contents.bangumi_id`（18,828 条），对应我们 `work.source_id`（source=bangumi）。
-- 为什么只存 subject_id、不存 content_id：首站每条都有 bangumi_id（唯一、一对一），
-- 我们只存 bangumi 档案，otaku_site 那批是误导入（见下），不需要第二套键。
--
-- 两个列的读数（在 2026-11-02 的生产副本上实测，见 docs/site-listed-migration.md）：
--   work      198,511 行 source=bangumi → 回填 18,828 行
--   work_tag  527,775 行              → 同步 18,828 部作品的标签行
-- 时间不写在这里（每台机器不同），看文档。

CREATE TABLE IF NOT EXISTS site_scope
(
    subject_id BIGINT UNSIGNED NOT NULL
        COMMENT '首站 contents.bangumi_id，对应 work.source_id（source=bangumi）',
    PRIMARY KEY (subject_id)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci
    COMMENT '首站收录范围（白名单）：不在表里的作品 app 不显示，库里仍然保留';

ALTER TABLE work
    ADD COLUMN site_listed TINYINT NOT NULL DEFAULT 0
        COMMENT '首站是否收录：1=app 显示；0=库里留着但不显示（≠ 已删除）';

ALTER TABLE work_tag
    ADD COLUMN site_listed TINYINT NOT NULL DEFAULT 0
        COMMENT '冗余自 work.site_listed：词表与标签筛选不 JOIN work，只能存一份';

-- ---------------------------------------------------------------------------
-- ① 清掉昨晚的哨兵时间
--
-- bangumi 那 17.2 万行是**真数据**，只是被借位藏起来了 → 还原成未删除。
-- otaku_site 那 1.09 万行是误导入的第二份目录（首站每条都能用 bangumi_id 对上，
-- 不需要另存一份）→ 把哨兵换成真正的删除时间，保留「删过」的事实，不留哨兵。
-- ---------------------------------------------------------------------------
UPDATE work
SET deleted_at = NULL
WHERE deleted_at = '2099-01-01 00:00:00'
  AND source = 'bangumi';

UPDATE work
SET deleted_at = NOW(3)
WHERE deleted_at = '2099-01-01 00:00:00';

-- ---------------------------------------------------------------------------
-- ② 回填白名单
--
-- 两边都用 `source` 收口：`site_scope.subject_id` 与 `otaku_site.source_id`（content_id）
-- 是两套号，只按数值 join 会撞出 3,015 条假匹配（11-02 在副本上实测过）。
-- ---------------------------------------------------------------------------
UPDATE work w
    JOIN site_scope s ON s.subject_id = CAST(w.source_id AS UNSIGNED)
SET w.site_listed = 1
WHERE w.source = 'bangumi'
  AND w.site_listed = 0;

-- work_tag 冗余列：只写值不同的行（全量 SET 会白写 50 万行）。
UPDATE work_tag t
    JOIN work w ON w.id = t.work_ref
SET t.site_listed = w.site_listed
WHERE t.site_listed <> w.site_listed;

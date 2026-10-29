-- 把 work_staff / work_characters 里引用到的人补进 people（Issue #271）
--
-- 背景：person_id 是「指向人物」的外键语义，但 people 一直是空的——19,399 个被引用的 id
-- 全悬空，人物页/人物跳转一查就是 404。导入侧从 2026-10-29 起会按需补壳（INSERT IGNORE），
-- 但这个补丁不追溯历史数据：关系没变时 applyRelations 根本不会被调用。
-- 所以存量数据要跑一次这个脚本。
--
-- 为什么能反复跑：INSERT IGNORE + uk_people_source(source, source_id)，重跑不增行、不改已有名字。
-- 名字来源要分清：work_staff.person_id 指制作人员本人（取 name），
-- work_characters.person_id 指的是**声优**（取 actor，不是角色名）。
--
-- 用法：mysql -u<user> -p <db> < scripts/backfill-people.sql

-- 1) 制作人员：同一人挂多个职位（作画监督 + 原画）时只建一行，名字取任意一条非空值。
INSERT IGNORE INTO people (source, source_id, name, entity_type)
SELECT w.source, s.person_id, MAX(s.name), 'person'
  FROM work_staff s
  JOIN work w ON w.id = s.work_ref
 WHERE s.person_id IS NOT NULL
   AND s.person_id <> ''
   AND s.name IS NOT NULL
   AND TRIM(s.name) <> ''
 GROUP BY w.source, s.person_id;

-- 2) 角色声优：person_id 在 characters 上指声优，名字必须取 actor。
--    取角色名（name）会在人物页看到一堆角色名当人名。
INSERT IGNORE INTO people (source, source_id, name, entity_type)
SELECT w.source, c.person_id, MAX(c.actor), 'person'
  FROM work_characters c
  JOIN work w ON w.id = c.work_ref
 WHERE c.person_id IS NOT NULL
   AND c.person_id <> ''
   AND c.actor IS NOT NULL
   AND TRIM(c.actor) <> ''
 GROUP BY w.source, c.person_id;

-- 3) 对账：仍被引用但 people 里没有的 id 数（正常应为 0；不为 0 说明有名字为空或超 200 字符）。
--    按 (source, person_id) 对账，不能只按 person_id —— uk_people_source 是两列联合唯一。
SELECT COUNT(*) AS dangling_person_ids
  FROM (SELECT w.source AS source, s.person_id AS person_id
          FROM work_staff s JOIN work w ON w.id = s.work_ref
         WHERE s.person_id IS NOT NULL AND s.person_id <> ''
        UNION
        SELECT w.source, c.person_id
          FROM work_characters c JOIN work w ON w.id = c.work_ref
         WHERE c.person_id IS NOT NULL AND c.person_id <> '') r
  LEFT JOIN people p ON p.source = r.source AND p.source_id = r.person_id
 WHERE p.id IS NULL;

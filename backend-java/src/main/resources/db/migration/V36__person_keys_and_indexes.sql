-- 人物键 v3 补齐 + 反查索引（b35 热修，承接 V33 / #362）
--
-- 1) V33 只把 work_staff / work_characters.person_id 改成了 bgm: 前缀，
--    people.source_id 仍是 v2 的裸数字。结果是作品详情返回 bgm:3818，
--    人物页按 bgm:3818 查 people 查不到 → 全站人物页 404（2026-11-07 发版后实测）。
--    这里把 people 的纯数字键补成 bgm:<id>，与 v3 数据集（people 映射同样产出 bgm:）对齐；
--    不补的话，下一次 v3 数据集导入 people 会因唯一键不同而插入重复行。
--
-- 2) 人物页反查一直缺 person_id 索引（V15 只有 work_ref 前缀索引），
--    V33 落地后迁移号不再被挡，这里补上：GET /api/persons/{id} 从 0.14–0.17 s
--    回到索引量级（生产 18 万 / 7.5 万行）。
--
-- 幂等：UPDATE 只碰纯数字键；索引用 information_schema 判存在后再建。
UPDATE people
   SET source_id = CONCAT('bgm:', source_id)
 WHERE source_id REGEXP '^[0-9]+$';

SET @idx_exists := (
    SELECT COUNT(*) FROM information_schema.STATISTICS
     WHERE table_schema = DATABASE()
       AND table_name = 'work_staff'
       AND index_name = 'idx_work_staff_person'
);
SET @ddl := IF(@idx_exists = 0,
    'ALTER TABLE work_staff ADD KEY idx_work_staff_person (person_id)',
    'SELECT 1');
PREPARE stmt FROM @ddl;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

SET @idx_exists := (
    SELECT COUNT(*) FROM information_schema.STATISTICS
     WHERE table_schema = DATABASE()
       AND table_name = 'work_characters'
       AND index_name = 'idx_work_characters_person'
);
SET @ddl := IF(@idx_exists = 0,
    'ALTER TABLE work_characters ADD KEY idx_work_characters_person (person_id)',
    'SELECT 1');
PREPARE stmt FROM @ddl;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

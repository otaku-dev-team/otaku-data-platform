-- 档 B 人物键 v3 落地（#362 / #398）：person_id 从裸数字键升级为带前缀键。
--
-- v3 数据集（sync-dataset v3，2026-11）把 work_staff / work_characters 的 person_id
-- 取值从「网站自增 id（裸数字）」改成统一前缀键（bgm:<人物 id> 强关联 /
-- pname:<人名> / cname:<公司名> 弱关联，见 docs/person-id-unification.md）。
-- 后端库里已有的 v2 裸数字键需就地改写，否则与 v3 数据集导入的新键（bgm:123）
-- 不相等，人物页关联会对不上。
--
-- 列宽 64 → 128，与 people.source_id（已为 128）对齐；pname:/cname: 弱关联键
-- 可能接近 64，扩到 128 避免截断丢键（#398 配套说明）。
--
-- 改写是幂等的：只给「纯数字、无前缀」的旧键加 bgm: 前缀，已带前缀的跳过；
-- 重复执行安全。people 表本期不导入（B2 人物页才用），无存量数据，不处理。

ALTER TABLE work_staff
    MODIFY COLUMN person_id VARCHAR(128) NULL
        COMMENT '人物实体标识（v3 起为带前缀键：bgm:/pname:/cname:）';

ALTER TABLE work_characters
    MODIFY COLUMN person_id VARCHAR(128) NULL
        COMMENT '声优的人物实体标识（v3 起为带前缀键，多数 bgm:）';

UPDATE work_staff
SET person_id = CONCAT('bgm:', person_id)
WHERE person_id IS NOT NULL
  AND person_id NOT LIKE 'bgm:%'
  AND person_id NOT LIKE 'pname:%'
  AND person_id NOT LIKE 'cname:%'
  AND person_id REGEXP '^[0-9]+$';

UPDATE work_characters
SET person_id = CONCAT('bgm:', person_id)
WHERE person_id IS NOT NULL
  AND person_id NOT LIKE 'bgm:%'
  AND person_id NOT LIKE 'pname:%'
  AND person_id NOT LIKE 'cname:%'
  AND person_id REGEXP '^[0-9]+$';

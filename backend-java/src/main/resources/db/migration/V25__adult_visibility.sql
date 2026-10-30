-- 成人内容对外不可见：把「是不是成人内容」落成两列，**不在查询时现算**。
--
-- 为什么不能查询时算（2026-10-31 线上 198,511 部 / 499,255 行 work_tag 实测）：
--   列表计数 COUNT(*)                    86 ms → 叠加 JSON_OVERLAPS 判断 2,714 ms（31 倍）
--   标签词表 GROUP BY tag                190 ms → 叠加 JOIN work + JSON_OVERLAPS 4,936 ms（26 倍）
--   词表只加 JOIN work（去掉 JSON 判断） 190 ms → 2,636 ms（14 倍）
-- 三条路都试过，结论一致：这两条查询本来就是全表 / 全索引扫描，任何逐行 JSON 解析或回表
-- 都会把成本乘上去；而它们分别在「每次列表请求」与「每次打开标签面板」的路径上。
-- 落成 TINYINT 之后只是行过滤，成本回到基线（86 ms / 190 ms）。
--
-- 为什么两张表都要存：work_tag 是标签筛选与词表计数唯一的数据源，词表查询不 JOIN work
-- （上面实测一 JOIN 就是 14 倍），所以只能在 work_tag 上冗余一份。
-- 与已有的 work_type / rating_value / release_year 冗余同一个理由，
-- 写入路径本来就是整组重写（WorkRepository#replaceTags），维护成本可接受。
--
-- 名单与 com.otaku.common.AdultTags 必须逐字一致：AdultTagsMigrationTest 会读这个文件比对，
-- 漂移直接红。改名单 = 改常量 + 加一条回填迁移（新作品由导入链路按常量自动打标）。
--
-- 打标口径只认「明确成人词」（R18 / 成年コミック / 里番 / 拔作 / 工口 / 無修正…），
-- 不收巨乳 / 纯爱 / BL-Game 这类题材词——它们在正常作品上也大量存在。
-- 实测命中 7,840 部（占在用作品 3.95%）：comic 3,439 / game 3,003 / anime 1,322 / novel 76。

ALTER TABLE work
    ADD COLUMN is_adult TINYINT(1) NOT NULL DEFAULT 0
        COMMENT '成人内容：1=对外不可见（列表/详情/推荐/词表/档期全部过滤）';

ALTER TABLE work_tag
    ADD COLUMN is_adult TINYINT(1) NOT NULL DEFAULT 0
        COMMENT '该行所属作品是否成人（= work.is_adult），供词表计数与标签筛选免 JOIN';

-- 存量回填。tags 为 NULL 的作品一律按非成人处理（is_adult 默认 0 已经是这个语义）。
UPDATE work
SET is_adult = 1
WHERE tags IS NOT NULL
  AND JSON_OVERLAPS(tags, CAST('["R18","R18G","R18c","R18漫画","R-18","R-18G","18X","18禁","18+","NSFW","成人","成人向","成人漫画","成人动画","里番","3D里番","旧里番","步兵里番","同人里番","步兵裡番","本子","本子分卷","H漫","H漫画","H本","黄漫","工口","拔作","黄油","小黄油","無修正","无修正","無修","无码","步兵","官能","官能小说","HGame","成年コミック","アダルト","アダルトコミック","エロ","エロ漫画","エロゲー","エロゲ","エッチ","官能小説","Hentai","3DHentai","HentaiAnime","3DHgame","ERO-ADV","ERO-GAL","EROGAME","EROGE","ERO-RPG","ERO-SLG","ERO-AVG","ERO-ACT","ero"]' AS JSON));

-- 只更新命中的行：全量 SET 会把 49 万行都写一遍，而其中 96% 的值没有变化。
UPDATE work_tag t
    JOIN work w ON w.id = t.work_ref
SET t.is_adult = 1
WHERE w.is_adult = 1;

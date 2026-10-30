-- 成人遮挡补丁：标题兜底。
--
-- 为什么 V25 不够：`R18!` 那个系列 7 部作品的 `tags` 是空的（来源没给标签），
-- 只按标签判定的话，用户在搜索框敲 `R18` 仍然能搜到它们——上线当天就是这个现象。
-- 判定改为「成人标签 OR 标题带成人标记」，标记名单在 com.otaku.common.AdultTags#TITLE_MARKERS。
--
-- 为什么只收这 7 个词（R18 / 18禁 / 18X / 無修正 / 无码 / Hentai / 里番）：
-- 实测标题里 `エロ` 有 293 部（未标记 213 部），但混着 `新吼えろペン`（吼えろ 里含 エロ）、
-- `マルドゥック・ヴェロシティ`（ヴェロシティ 里含 エロ）；`成人` 33 部里有 `成人仪式`、
-- `爱的成人式`。按这两个词兜底会把正常作品整部藏掉，比漏掉几部成人作品更糟。
-- 上面这 7 个词实测命中 24 部，全是成人内容（代价：4 部「重生到 18 禁游戏世界」的轻小说
-- 会被一起藏，可接受）。
--
-- 与 Java 侧一致：LIKE 在 utf8mb4_0900_ai_ci 下大小写不敏感，与 titleLooksAdult 的
-- 小写包含判断同语义。AdultTagsMigrationTest 会比对两处名单，漂移直接红。
UPDATE work
SET is_adult = 1
WHERE is_adult = 0
  AND (title LIKE '%R18%'
    OR title LIKE '%18禁%'
    OR title LIKE '%18X%'
    OR title LIKE '%無修正%'
    OR title LIKE '%无码%'
    OR title LIKE '%Hentai%'
    OR title LIKE '%里番%');

-- 同步冗余列：词表计数与标签筛选读的是 work_tag.is_adult，漏了这一步等于没打标。
UPDATE work_tag t
    JOIN work w ON w.id = t.work_ref
SET t.is_adult = 1
WHERE w.is_adult = 1;

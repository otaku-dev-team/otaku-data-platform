-- 人物 id 口径的实测脚本：一次跑出 D1 / D2 需要的全部数字。
--
-- 为什么要有这个：本机 dev 库只有 11 部作品，content_cast / content_credits /
-- content_studios 全是 0 行，量不出任何比例。生产库里到底有多少人、多少公司、
-- 两套 id 实际撞多少、弱关联（同名）会把多少条并成一条——这些数字决定
-- 「前缀键方案看起来准不准」，不能靠估。
--
-- 用法（在库所在的机器上跑，数据不出服务器）：
--   sqlite3 /path/to/app.db < scripts/person-coverage.sql
-- 或交互式：
--   sqlite3 /path/to/app.db
--   sqlite> .read scripts/person-coverage.sql
--
-- 输出是「指标 | 值」两列，直接贴回来即可。
--
-- 注意：本脚本只读，不建表、不写库。

.mode list
.separator " | "

select '--- 角色 · 声优（content_cast）' as metric, '' as value
union all
select 'cast 总行数', count(*) from content_cast
union all
select 'cast 有 person_id', count(*) from content_cast
 where person_id is not null and trim(cast(person_id as text)) <> ''
union all
select 'cast 无 person_id', count(*) from content_cast
 where person_id is null or trim(cast(person_id as text)) = ''
union all
select 'cast 去重 person_id', count(distinct cast(person_id as text)) from content_cast
 where person_id is not null and trim(cast(person_id as text)) <> ''
union all
select 'cast 去重 actor 名（归一后）',
       count(distinct trim(replace(replace(replace(actor, '　', ' '), '  ', ' '), '  ', ' ')))
  from content_cast

union all
select '--- 制作人员（content_credits）', ''
union all
select 'credits 总行数', count(*) from content_credits
union all
select 'credits 有 person_id', count(*) from content_credits
 where person_id is not null and trim(cast(person_id as text)) <> ''
union all
select 'credits 无 person_id', count(*) from content_credits
 where person_id is null or trim(cast(person_id as text)) = ''
union all
select 'credits 去重 person_id', count(distinct cast(person_id as text)) from content_credits
 where person_id is not null and trim(cast(person_id as text)) <> ''
union all
select 'credits 去重 name（归一后）',
       count(distinct trim(replace(replace(replace(name, '　', ' '), '  ', ' '), '  ', ' ')))
  from content_credits
union all
-- 弱关联的代价：改名归一后仍有多条的不同名字个数 = 会被人为并成一条的规模
select 'credits 里归一后重名的人名个数',
       count(*) from (
         select trim(replace(replace(replace(name, '　', ' '), '  ', ' '), '  ', ' ')) as n
           from content_credits
          where person_id is null or trim(cast(person_id as text)) = ''
          group by n having count(*) > 1
       )

union all
select '--- 实体花名册（entities）', ''
union all
select 'entities 总行数', count(*) from entities
union all
select 'entities 有 bangumi_person_id', count(*) from entities
 where bangumi_person_id is not null and trim(cast(bangumi_person_id as text)) <> ''
union all
select 'entities 里 entity_type=person', count(*) from entities where entity_type = 'person'
union all
select 'entities 里 entity_type=company', count(*) from entities where entity_type = 'company'

union all
select '--- 制作公司（content_studios）', ''
union all
select 'studios 总行数', count(*) from content_studios
union all
select 'studios 去重公司名',
       count(distinct trim(replace(replace(replace(name, '　', ' '), '  ', ' '), '  ', ' ')))
  from content_studios

union all
select '--- 两套 id 撞车实际规模（ROADMAP 记的 4,115 就是这个）', ''
union all
select 'entities.id ∩ cast.person_id',
       count(*) from (
         select cast(person_id as text) as pid from content_cast
          where person_id is not null and trim(cast(person_id as text)) <> ''
         intersect
         select cast(id as text) from entities
       )
union all
select 'entities.id ∩ credits.person_id',
       count(*) from (
         select cast(person_id as text) as pid from content_credits
          where person_id is not null and trim(cast(person_id as text)) <> ''
         intersect
         select cast(id as text) from entities
       )

union all
select '--- 关系表覆盖的作品数（决定「多少作品有这批人可点」）', ''
union all
select '有 credits 的作品数', count(distinct content_id) from content_credits
union all
select '有 cast 的作品数', count(distinct content_id) from content_cast
union all
select '有 studios 的作品数', count(distinct content_id) from content_studios
union all
select 'contents 总行数', count(*) from contents;

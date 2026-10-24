# W2 · 搜索扩面评估：为什么 ngram 不能直接用

> 起草：@pyxz0 ｜ 2026-10-24 ｜ 归口 Issue #96 · W2
> **状态：评估完成，结论是「本轮不改」。** 这不是「没空做」，而是实测下来
> 唯一省事的做法会**静默丢搜索结果**，比慢更糟。

## 1. 结论先行

`q` 现在是 `title LIKE '%关键词%'`，前导通配符用不上 `idx_work_title`，只能全表扫。
给 `title` 加 ngram 全文索引看起来是标准解法，但**实测它不能替代 LIKE**：

| 结论 | 证据（MySQL 8.0.46，`ngram_token_size=2`） |
|---|---|
| ① 单字查询完全失效 | `LIKE '%龙%'` 命中 1 条 → `MATCH ... AGAINST('龙')` **命中 0 条** |
| ② 双字查询会**漏召回** | `LIKE '%ab%'` 命中 3 条 → `MATCH ... AGAINST('ab')` **命中 0 条**；同一张表 `'bc'` 两边都命中 3 条 |
| ③ 短语查询不是精确子串 | `MATCH ... AGAINST('"abc"')` 会命中 `xabxbcx`（不含连续 `abc`），是**超集**不是等集 |

第 ② 条是决定性的：**只要存在一个 LIKE 命中而 MATCH 不命中的反例，「MATCH 当预过滤 + LIKE 精确校验」
这个方案就不成立**——预过滤漏掉的行，后面的 LIKE 再精确也救不回来，用户看到的是「搜不到」。

> 根因未完全定位：`ab` 不在 InnoDB 默认停用词表里（该表只有 a/about/an/… 那 36 个词），
> `'bc'` 又正常。可能是 ngram 分词器对特定 2 字符 ASCII 的处理，没继续深挖——
> **结论不依赖根因**，有一个可复现的反例就足够否掉方案。

## 2. 现状成本（引用既有实测，非本次新测）

| 场景 | 55.6 万条实测 | 来源 |
|---|---|---|
| `q` + `tag` 组合 | 约 720ms | ROADMAP §8.4 |
| 纯 `tag` 筛选 | 20–31ms | V7 建立时实测 |
| 深页 `LIMIT/OFFSET`（默认排序第 11000 页） | 约 490ms | ROADMAP §8.4 已知限制 |

本机当前库只有 107 条，**本次没有做任何性能测量**，上面三行都是引用别人/先前的实测记录。

## 3. 三个选项与代价

### 选项 A：接受语义变更，直接换 ngram（不推荐）

把 `q` 的定义从「子串匹配」改成「分词匹配」，并规定「单字查询不支持」。

- 代价：契约 §6.1 的 `q` 语义要改（红线，三人确认）；客户端搜索框必须挡掉单字查询；
  且第 ② 条说明即便多字查询也会漏——**这是数据缺陷，不是性能取舍**。
- 收益：未测，可能从 700ms 级降到几十毫秒。

**否决理由：用正确性换速度，且收益未验证。**

### 选项 B：自建 bigram 倒排表（唯一能保语义的方案）

照 `work_tag` 的路子，再建一张 `work_title_bigram (bigram, work_ref)`：

```sql
-- 写入时把 title 切成所有 2 字片段（中文按字符、ASCII 按字符），与 work 同事务更新
CREATE TABLE work_title_bigram (
  bigram   CHAR(2)        NOT NULL,
  work_ref BIGINT UNSIGNED NOT NULL,
  PRIMARY KEY (bigram, work_ref)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

查询：`q` 切成 2 字片段 → 求交集拿候选 → **回表用 LIKE 做精确判定**。
因为「含 `abc`」必然「含 `ab` 且含 `bc`」，倒排结果是**真超集**，精确性由 LIKE 兜底。

- 代价：55.6 万条标题按平均 20 字算约 **1,000 万行**（`work_tag` 目前约 150 万行，量级差 7 倍）；
  导入路径多一次整组重写；1 字查询仍需回退 LIKE。
- 收益：未测。**没有全量数据就不能承诺数字**——这是本项目对外材料的硬约束。

**这是唯一在语义上安全的方案，但成本明显高于一个「顺手优化」，应单独立项。**

### 选项 C：不改，把成本讲清楚（本轮选择）

- `q` 只在用户主动搜索时付出一次全表扫；列表页（无 `q`）不受影响。
- 已收窄的路径仍然有效：先选 `type` / `tag` 再搜，比全库裸搜便宜（`tag` 走反查表）。
- 客户端可以做输入防抖，避免每敲一个字打一次全表扫。

## 4. 建议

1. **本轮不做**。`q` 的性能问题登记为已知成本，不夹在功能 PR 里。
2. 真要动，**走选项 B**，单独立项，前置条件是「有 55.6 万数据集可测」。
3. 如果产品能接受「搜索改为分词匹配、且不支持单字」，再回到选项 A——这需要产品拍板，
   不是后端能单方面决定的。

## 5. 复现本次实验

```sql
CREATE TABLE ft_probe (
  id INT AUTO_INCREMENT PRIMARY KEY,
  title VARCHAR(200) NOT NULL,
  FULLTEXT KEY ft_title (title) WITH PARSER ngram
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

INSERT INTO ft_probe (title) VALUES
 ('街角魔族'),('街角魔族 2丁目'),('魔法少女小圆'),
 ('xabxbcx'),('abcde'),('the abc'),('的'),('龙与虎');

-- ② 漏召回：3 条 vs 0 条
SELECT id FROM ft_probe WHERE title LIKE '%ab%';            -- 3
SELECT id FROM ft_probe WHERE MATCH(title) AGAINST('ab');   -- 0

-- ① 单字失效：1 条 vs 0 条
SELECT id FROM ft_probe WHERE title LIKE '%龙%';            -- 1
SELECT id FROM ft_probe WHERE MATCH(title) AGAINST('龙');   -- 0

-- ③ 短语是超集：命中不含连续 abc 的 xabxbcx
SELECT id FROM ft_probe WHERE MATCH(title) AGAINST('"abc"' IN BOOLEAN MODE);
```

## 6. 未做 / 不知道

- **没有性能数据**：本机无全量库，选项 B 的收益完全是推断，不能引用。
- **没测 `q` 单独查询的耗时**：只知道 `q + tag` 约 720ms；`q` 单独是否同量级未实测。
- **没验证 bigram 表的实际行数与导入耗时**：1,000 万行是按平均标题长度估的，不是实测。
- **根因没查到底**：为什么 `'ab'` 漏而 `'bc'` 不漏，只确认了现象可复现。

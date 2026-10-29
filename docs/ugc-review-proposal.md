# 点评（长评 + 评分）方案 · 待拍板

> 状态：**方案留档，未生效**。归属 #240 B2c 剩余项。主责 @pyxz0。
> 与 [`ugc-retention-proposal.md`](ugc-retention-proposal.md) 同一批：先定口径，再写代码。

## 1. 为什么不能直接开工

「评论」和「点评」在 Issue #240 里是并列的两个词，但没有定义差别。实查后有三个绕不开的岔路：

| 岔路 | 现状 | 不定会怎样 |
|---|---|---|
| 点评带不带评分 | 作品已有来源站聚合分 `main_rating`（首站 `/api/contents/{id}` 的 `rating`，如 7.8） | 两套分并存时，客户端不知道该显示哪个；改名/合并都会返工 |
| 与收藏的关系 | `collection` 只有 `status`（want / watching / watched），**没有评分与短评字段** | 若点评写进 collection，等于改阶段 2 已验收的表；若独立，又要定「没收藏能不能评」 |
| 一人一条还是多条 | `ugc_comment` 是可多条、可回复的讨论流 | 点评若也允许多条，「评价」就退化成第二个评论区 |

## 2. 三种形态

| | A · 并入收藏 | B · 评论表加类型 | C · 独立表（推荐） |
|---|---|---|---|
| 数据 | `collection` 加 `rating` / `review` / `review_status` | `ugc_comment` 加 `kind='review'` + `rating` + 唯一键 | 新表 `ugc_review(work_id, user_id, rating, body, status, ...)` |
| 一人一条 | 天然（`uk_collection_user_work` 已有） | 需要生成列做唯一键（MySQL 对 NULL 不参与唯一，直接加 `uk(user,work)` 没用） | 天然（`uk_review_user_work`） |
| 复用审核/举报/删除/留存 | 全部要重写 | 全部继承 | 要再接一遍（或抽公共层） |
| 风险 | **动阶段 2 已验收的契约**，客户端收藏流程要改 | 短评与长评混表，列表要分流，`body` 上限两套 | 多一张表、多一套端点，但边界最清 |

**推荐 C**，理由：
- collection 是阶段 2 验收过的跨端同步核心，加字段会让「收藏 = 状态 + 评分 + 短评」这个语义渗进客户端所有收藏逻辑；
- 点评的字段会长（剧透标记、评分维度、编辑器内容），塞进 comment 会把两个产品硬焊在一张表；
- 审核/举报/删除/留存可以抽一层 `ugc_*` 公共能力，第二次接比第一次便宜。

## 3. 推荐形态下的接口草案（未生效，仅示意）

```
GET    /api/works/{work_id}/reviews?page=&page_size=&sort=recent|helpful
GET    /api/works/{work_id}/reviews/summary      # 均分、各分段人数、总数
POST   /api/me/reviews                            # {work_id, rating(1-10,可空), body}
PATCH  /api/me/reviews/{id}                       # 只能改自己的
DELETE /api/me/reviews/{id}                       # 软删
```

- `rating` 可空：允许「只写长评不打分」，与首站「打分是收藏动作的一部分」不完全一致，但更宽容；
- 均分用**平台用户自己打的**，与 `main_rating`（来源站分）**并列展示、不互相覆盖**——
  混成一个数就再也分不清是谁的口径（契约 §3.2 的边界同理）。

## 4. 三个必须拍板的点

1. **要不要「看过才能评」？**
   首站与 Bangumi 的习惯是「收藏（看过）后才能打分」。强制的话，点评前必须先有
   `collection.status='watched'`；不强制则新用户可以先评后收藏。我倾向**不强制**，
   但在 UI 上引导「先标记看过」——强制会把「想吐槽但还没看完」的人挡在门外。
2. **平台自建评分要不要做？**
   做了就有两套分（来源站 / 平台），必须并列展示且各自标注口径；不做则点评只有文字。
   我倾向**做**，因为「评分」是点评最有信息量的部分，且是 G1「体验优于原页」的抓手。
3. **点评与评论是否互相打通？**
   我倾向**不打通**：评论是作品页的讨论（可回复、多条），点评是一人一条的评价（可打分）。
   两者在客户端是两个 tab，不做「把点评转成评论」这类转换。

## 5. 若 C 被否，退路是什么

- 选 A：改动最小（复用 collection 与现有同步），但要在阶段 2 契约上加字段，
  客户端收藏页要同时展示评分与短评，回归面比看上去大。
- 选 B：复用最彻底，但「一人一条」的唯一约束要用生成列
  （`ALTER TABLE ugc_comment ADD COLUMN review_key VARCHAR(64) AS (IF(kind='review', CONCAT(user_id,'-',work_id), NULL)) STORED, ADD UNIQUE KEY uk_review(review_key)`），
  且列表查询永远要带 `kind` 过滤——一处漏写就会把长评混进评论区。

## 6. 本期先做了什么（不等口径）

- **编辑评论**（B2c④）：`PATCH /api/me/comments/{id}`，只改正文；先审后发的站点编辑后回 `pending`。
  点评将来若选 C，编辑逻辑可平移到 `ugc_review`。
- 点评实现**等本方案拍板**，不写半成品。

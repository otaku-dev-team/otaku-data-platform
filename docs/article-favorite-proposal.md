# 资讯收藏方案 · 待拍板

> 状态：**方案留档，未生效**。归属 #377（客户端 @riceyu02）；后端实现归 @pyxz0。
> 本文只定口径，**不改 `docs/openapi.yaml`、不代三人确认**（章程 §3.2）。

## 1. 为什么不能直接开工

#377 原文写「依赖：后端资讯收藏接口（网站已有，需客户端对接）。本项依赖最少、最独立」。
实查后这个前提**不成立**——网站有，不等于平台有：

| 事实 | 证据 |
|---|---|
| 平台后端没有资讯收藏 | `docs/openapi.yaml` 全部 path 里搜不到任何 `favorite`；`backend-java/src/main/java/com/otaku/article/` 只有导入与详情读取 |
| 网站那个接口不能用 | `POST /articles/{id}/favorite` 是**来源站自己的接口**。章程口径是平台只读拉取来源站、不由我们定义来源站接口，不能拿客户端直连 |
| 客户端现有收藏接不上 | `CollectionController` / `CollectionCache` / 收藏页全部绑定 `work_id` 与 `want / watching / watched` 三态，资讯没有状态概念 |

结论：这是**新增跨模块契约**（红线），要三人确认 → 改 openapi → 后端实现，客户端才接得上。
在此之前写客户端代码，只能对着一个不存在的端点写 mock。

## 2. 三个岔路

| 岔路 | 选项 | 不定会怎样 |
|---|---|---|
| **存哪** | A 复用 `collection`（加类型列）／ **B 独立表** | `collection.work_id` 的语义是 `work.work_id`，且有 `uk_collection_user_work`；塞 `article_id` 进去后两类 id 混一列，收藏页必须按类型分流，而资讯又没有三态 |
| **接口形态** | **A 对齐现有收藏**（PUT / DELETE 幂等）／ B 网站式 `POST /articles/{id}/favorite` | B 没有幂等、没有对称的「取消」方法，客户端要维护第二套状态机，且与 `/api/me/*` 的既有风格不一致 |
| **收藏夹** | A 合并进 `/api/me/collections`（改已验收 schema）／ **B 独立端点 + 客户端分段** | A 要动阶段 2 已验收的 `CollectionPage`，影响所有收藏相关测试与离线缓存键 |

**推荐：B / A / B。**

## 3. 推荐形态

### 3.1 表（建议迁移号 V35，见 §4.3）

```sql
CREATE TABLE IF NOT EXISTS article_favorite
(
    id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    user_id    BIGINT UNSIGNED NOT NULL COMMENT 'app_user.id',
    article_id VARCHAR(32)     NOT NULL COMMENT 'article.article_id（不建外键，理由同 collection）',
    created_at DATETIME(3)     NOT NULL,
    updated_at DATETIME(3)     NOT NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uk_article_favorite_user_article (user_id, article_id),
    KEY idx_article_favorite_user_updated (user_id, updated_at),
    CONSTRAINT fk_article_favorite_user FOREIGN KEY (user_id) REFERENCES app_user (id)
) ENGINE = InnoDB;
```

不建到 `article` 的外键，与 `collection` 对 `work` 的处理保持同一理由：内容同步与个人数据解耦。
`article_id` 是 `VARCHAR(32)` 的不透明标识（`V9__article.sql`），**不是**自增主键、也不是来源站的 `source_id`。

### 3.2 四个端点（与作品收藏同构）

```
GET    /api/me/article-favorites?page=&page_size=
GET    /api/me/article-favorites/{article_id}
PUT    /api/me/article-favorites/{article_id}      # 幂等 upsert
DELETE /api/me/article-favorites/{article_id}      # 幂等，204
```

契约要点（逐条对齐 `/api/me/collections`）：

- **未收藏是正常结果**：`200` + `favorited: false`；只有资讯本身不存在才 `404`。
- **PUT 幂等**：记录不存在则创建，已存在则刷新 `updated_at`；重复提交结果一致，不用 `201`。
- **DELETE 幂等**：记录不存在也返回 `204`（对齐 `deleteCollection`）。
- **列表**：`updated_at DESC, article_id ASC`（第二键防同秒翻页跳条）；返回资讯摘要，**不含 `body`**；
  空收藏 `200` + `items: []` + `total: 0`。
- **鉴权**：全部 `bearerAuth`；401 语义与现有 `/api/me/*` 一致。

### 3.3 客户端

- **详情页**调 `GET /api/me/article-favorites/{article_id}` 拿 `favorited`，**不改 `ArticleDetail` 契约**——
  与作品详情页的做法一致（`WorkDetail` 里也没有 `collected`，是单独查的）。
- **收藏页**加分段：作品 / 资讯。资讯项复用现有资讯卡，操作只有「取消收藏」。
- **离线**：复用 `CollectionCache` 那套「接口 + Hive + 内存」结构，缓存键**第一维仍是 `userId`**（同 `CollectionCacheKey` 的理由：漏了就是隐私事故）；离线只读、不假成功。

## 4. 必须拍板的点（#377 评论区拍完即可回填）

1. **表**：独立 `article_favorite`（推荐）vs `collection` 加 `target_type`（动已验收表）。
2. **端点命名**：`/api/me/article-favorites` 是否接受（与 `/api/me/collections` 并列，还是 `/api/me/favorites/articles`）。
3. **迁移号**：V35 只是按 2026-11-05 排期推的（V32 已上线、V33 = #362 前缀键+列宽、V34 = #408 映射表）；
   合入时以实际最大号为准，**别照着本文写死**。
4. **资讯被删/下线时**：收藏列表过滤掉（推荐，`article` 目前没有 `deleted_at`，将来加软删要同步加条件）
   还是保留占位。

## 5. 若独立表被否，退路是什么

`collection` 加 `target_type ENUM('work','article')` + `work_id` 改名 `target_id`。
代价：改阶段 2 已验收的表与契约、客户端全部收藏逻辑、`uk_collection_user_work` 要重建，
且 `status` 对资讯恒 `null`（三态在资讯上没有意义）。**不建议**，列在这里是为了拍板时能对比。

## 6. 本期先做什么（不等拍板）

- 客户端可以先做**只读的资讯收藏列表 UI 骨架**（mock 数据源），做法同 #427 的画像壳：
  只搭页面与空/错态，不定义跨端契约、不写死字段名。
- 真数据联调必须等后端接口 + 契约落地。

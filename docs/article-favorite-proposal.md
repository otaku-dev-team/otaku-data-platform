# 资讯收藏方案 · 后端已实现（2026-11-07）

> 状态：**方案已生效，后端已上线**（`V34__article_favorite.sql` + `/api/me/article-favorites`，2026-11-07 b34），
> 客户端待接真接口（#452 的只读骨架可直连）。
> 归属 #377（客户端 @riceyu02）；后端实现 @pyxz0。
>
> ⚠️ **2026-11-05 复核**：#435 的「otaku 自运营，多站/交付类约束对自家站可让步」口径，
> 让本文 §1 里「平台不代理来源站接口」这条理由不再成立（见新增的 §7）。
> 三个岔路的**推荐值不变**，但多了一个「平台后端代理站点接口」的备选，需要一并对比后再拍。

## 1. 为什么不能直接开工

#377 原文写「依赖：后端资讯收藏接口（网站已有，需客户端对接）。本项依赖最少、最独立」。
实查后这个前提**不成立**——网站有，不等于平台有：

| 事实 | 证据 |
|---|---|
| 平台后端没有资讯收藏 | `docs/openapi.yaml` 全部 path 里搜不到任何 `favorite`；`backend-java/src/main/java/com/otaku/article/` 只有导入与详情读取 |
| 网站那个接口不能让客户端直连 | `POST /articles/{id}/favorite` 是**来源站自己的接口**。初版据此写「平台只读拉取、不代理来源站接口」——#435 之后这条理由只对「客户端直连」成立，平台后端代理已可行（见 §7） |
| 客户端现有收藏接不上 | `CollectionController` / `CollectionCache` / 收藏页全部绑定 `work_id` 与 `want / watching / watched` 三态，资讯没有状态概念 |

结论：这是**新增跨模块契约**（红线），要三人知悉 → 改 openapi → 后端实现，客户端才接得上。
在此之前写客户端代码，只能对着一个不存在的端点写 mock。
仍不让步的一条：**客户端不直连来源站**（#435 明确保留，理由与平台自建表无关）。

## 2. 三个岔路

| 岔路 | 选项 | 不定会怎样 |
|---|---|---|
| **存哪** | A 复用 `collection`（加类型列）／ **B 独立表** | `collection.work_id` 的语义是 `work.work_id`，且有 `uk_collection_user_work`；塞 `article_id` 进去后两类 id 混一列，收藏页必须按类型分流，而资讯又没有三态 |
| **接口形态** | **A 对齐现有收藏**（PUT / DELETE 幂等）／ B 网站式 `POST /articles/{id}/favorite` | B 没有幂等、没有对称的「取消」方法，客户端要维护第二套状态机，且与 `/api/me/*` 的既有风格不一致 |
| **收藏夹** | A 合并进 `/api/me/collections`（改已验收 schema）／ **B 独立端点 + 客户端分段** | A 要动阶段 2 已验收的 `CollectionPage`，影响所有收藏相关测试与离线缓存键 |

**推荐：B / A / B。**

## 3. 推荐形态

### 3.1 表（迁移号见 §4.3，不写死）

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
3. **迁移号**：**不写死**，以合入时 `ls ... | sort -V` 的实际最大号为准。
   实际落地（2026-11-07）：V33 已被 #362（人物键前缀 + 列宽）占用，本文用 **V34**。
   #408 的映射表方案已撤销（#436），没有占号。
4. **资讯被删/下线时**：收藏列表过滤掉（**已按此实现**：列表与计数都 `JOIN article`，
   没有 article 行的收藏不占位；将来 `article` 加软删要同步加条件）。

## 5. 若独立表被否，退路是什么

`collection` 加 `target_type ENUM('work','article')` + `work_id` 改名 `target_id`。
代价：改阶段 2 已验收的表与契约、客户端全部收藏逻辑、`uk_collection_user_work` 要重建，
且 `status` 对资讯恒 `null`（三态在资讯上没有意义）。**不建议**，列在这里是为了拍板时能对比。

## 6. 本期先做什么（不等拍板）

- 客户端可以先做**只读的资讯收藏列表 UI 骨架**（mock 数据源），做法同 #427 的画像壳：
  只搭页面与空/错态，不定义跨端契约、不写死字段名。
- 真数据联调必须等后端接口 + 契约落地。

## 7. 新口径下的复核（2026-11-05，#435）

zm 在 #378 / #435 拍了一条全局口径：**总方案里为「多站接入 / 客户交付 / 不越权动别人站点」
设的约束，对 otaku 自家站不成立**。与本方案直接相关的是这两条：

| 旧约束 | 对 otaku 自运营 |
|---|---|
| 只读拉来源站、不代理不改它的接口 | 站是自己的：接口可以要、可以加白名单、可以改 |
| 契约「不回写 / 不落库」 | 可以落库，换体验 |

于是多出一个**初版没考虑的备选 D**：平台后端代理站点
`POST /articles/{id}/favorite`（客户端打 `/api/me/...`，后端转发到站点）。
它不再因「不代理」被一票否决，但**仍不让步的四条**里「客户端不直连来源站」要守住——
D 满足这一条，所以只是「可行」，不是「自动胜出」。

### 为什么仍推荐 B / A / B（自建 `article_favorite`）

1. **离线与跨端**：现有收藏链路是「接口 + Hive + 内存」三层，缓存键按 `userId` 隔离。
   代理站点接口就拿不到本地数据主权，离线只读、登出清理都要另写一套；
2. **注销即清个人数据**（#435 明确保留）：自建表可以直接在删除监听里清掉；
   代理模式下平台不知道站点那份收藏算不算「本用户的个人数据」，容易漏；
3. **幂等与一致性**：站点 `POST` 没有对称的取消方法、没有幂等承诺，
   自建的 `PUT` / `DELETE` 与 `/api/me/collections` 同构，客户端只需一套状态机；
4. **站点接口会变**：自家站可以改，但那仍是跨仓库的耦合；平台收藏是我们自己的产品语义
   （分段、计数、空态），不该由站点接口的形状决定。

### 需要补拍的一点

原 §4 四个拍板点之外，加一条：**是否明确排除「平台代理站点接口」这条备选**。
若有人主张走代理（省掉建表与迁移），请先把上面第 2 条（注销即清）的落地方案写出来，
否则不建议改推荐值。

其余结论不变：A 项「菜单丰富化」里与 #377 无关的部分已在 #434 落地。

## 8. 落地记录（2026-11-07，后端）

| 项 | 实现 |
|---|---|
| 表 | `V34__article_favorite.sql`：`article_favorite(user_id, article_id)` 唯一键 + `(user_id, updated_at)` 索引 |
| 端点 | `GET /api/me/article-favorites`、`GET/PUT/DELETE /api/me/article-favorites/{article_id}` |
| 列表 | `updated_at DESC, article_id ASC`；`items[].article` 复用 `ArticleSummary`（**不含正文**）；`page_size` 上限 50 |
| 幂等 | `PUT` 用唯一键 + `ON DUPLICATE KEY UPDATE`，重复提交不产生第二行；`DELETE` 记录不存在也 204 |
| 404 | 只有资讯不存在才 `404 ARTICLE_NOT_FOUND`；未收藏是 `200 + favorited:false` |
| 隔离 | 全部走 `/api/me/**`（AuthFilter），`user_id` 只从会话取；集成测试含双用户隔离用例 |
| 验证 | 后端 500 通过 / 0 skipped（新增 6 条真库 IT）；`check-contract.py` 74 path / 132 $ref / 112 schema |

客户端接入（riceyu）：`article_favorite_data_source.dart` 的三步照文件头做即可；
详情页的 `favorited` 单独查，**不改 `ArticleDetail`**——与作品详情页的 `collected` 同口径。

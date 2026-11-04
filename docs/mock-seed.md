# 模拟用户行为种子（#415）

> 给「开发期没有真实用户行为」兜底。**只在 dev 生效，绝不进生产**。

## 为什么需要

2026-11-04 的生产实测：`collection` / `ugc_review` / `ugc_comment` 全 0 行，`app_user` 只有 2 个，
浏览连表都没有。画像（#401）、推荐（#402）、统一服务（#413）在这种库上跑，对每个用户都返回空结果——
调参调的是空气。

zm 的决策是：**开发期用模拟数据绕过，生产期真实信号来了无缝切换**。

## 怎么用

```bash
# 种 300 个用户 / 最近 60 天的行为（可重复执行，先清后种）
./mvnw spring-boot:run -Dspring-boot.run.profiles=dev \
    -Dspring-boot.run.arguments="--seed-mock --app.mock-seed.users=300 --app.mock-seed.seed=42"

# 换个分布
... --app.mock-seed.users=200 --app.mock-seed.seed=7 --app.mock-seed.days=30

# 只清空（删 mock 用户及其行为，真实用户一条不碰）
... -Dspring-boot.run.arguments="--seed-mock --app.mock-seed.clear=true"
```

也可以走环境变量（`OTAKU_MOCK_SEED_ENABLED` / `_USERS` / `_RANDOM` / `_DAYS` / `_CLEAR`），
`application.yml` 里给了默认值。

## 三道门，缺一不可

| 门 | 位置 | 作用 |
|---|---|---|
| `@Profile("dev")` | `MockSeedRunner` | 生产包里这个 bean **根本不存在**，不是靠 if 判断 |
| 开关 | `app.mock-seed.enabled` 或命令行 `--seed-mock` | 默认关；不显式开就不写库 |
| 燃料检查 | `MockSeedService` | 没有可见作品或标签词表直接报错，不写半套 |

## 写哪四张表、怎么标记

| 表 | 写什么 |
|---|---|
| `app_user` | `identity_source='mock'`、用户名 `mock-0001…`、`password_hash='mock-no-login'`（登录不了，也不需要） |
| `user_work_view` | 浏览：有界行，一人一片一行 + `view_count` |
| `collection` | 收藏：浏览的子集（约 25%），状态 `want` / `watching` |
| `ugc_review` | 评分：浏览的子集（约 18%），`body` 为空（只打分），`status='published'` |

清空只按 `identity_source='mock'` 删，真实用户与他们的行为一条不动。

## 生成模型（固定种子可复现）

1. 从热门标签（`work_tag` 前 200）里按热度抽 **2–4 个口味标签**；
2. 每个用户看 **8–40 部**（幂律，多数人少、少数人多），菜谱 = 口味标签下的作品 + 少量全站热门；
3. 收藏 = 浏览子集；评分 = 浏览子集，`6.0 + 命中口味数 × 1.0 + 噪声(±1.2)`，截到 1–10。

第 3 条是**故意**让评分与口味正相关：否则拿这批数据调推荐权重时，学到的是一条自造的假相关，
数字好看、上线全错。这条相关性有单测钉住（`MockTasteGeneratorTest`）。

## 已知边界

- **站点**：`app_user.site_key` 有外键指着 `site`，所以站点从库里现有 active 行取（不写死站名，
  `check-site-isolation` 会拦）；库里没有站点时用户不带 site_key、且不写评分（`ugc_review.site_key` 非空）。
- **作品范围**：不按 `site_listed` 过滤。dev 库里通常没有收录清单，按它过滤会让种子一条都跑不起来；
  可见性由 profile 门保证（写不到生产）。
- **不复刻真实分布**：这里只保证「画像能算出东西、信号有方向」，不保证与线上人群分布一致。

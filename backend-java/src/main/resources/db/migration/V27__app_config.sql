-- 运行期可改的配置（热更新层）。
--
-- 为什么要有这张表：以前"改一点东西"= 改 Java 常量 → 重新打包 → 传 jar → 重建容器。
-- 2026-10-31 一天里为了成人词表发了两次版，就是这个成本。这张表把「会变的运营参数」
-- 从代码里挪出来：改一行数据 + 一个 PUT，客户端下次拉取即生效，不发版、不重启。
--
-- 为什么是 key + JSON 而不是一堆列：
--   1) 值的形状天然多样（布尔开关 / 字符串数组 / 对象），列存要么全 TEXT 要么随需求加列；
--   2) 消费方（客户端 / 后端）各自取自己认识的键，加新键不需要迁移；
--   3) MySQL 的 JSON 列会做校验，手写坏 JSON 会当场报错，比 TEXT 静默存坏强。
--
-- 为什么没有 version 列：版本就是 MAX(updated_at) 的毫秒值，写入时天然递增，
-- 少一个要维护的自增序列，也不会出现「版本号回退导致客户端缓存不刷新」。
--
-- 默认值不写在这里，也没有 seed：**缺键 = 用代码默认**（成人词表在
-- com.otaku.common.AdultTags，公告等客户端配置缺键即视为关闭）。这样代码里的默认值改了
-- 立即对全新环境生效，不会出现「库里的旧副本把新默认值盖住」；运维想改就直接 PUT 覆盖。
-- 在 SQL 里再抄一份名单会变成三处同步，而漂移是静默的（漏一个词 = 少藏一片作品）。
CREATE TABLE IF NOT EXISTS app_config
(
    config_key   VARCHAR(64)  NOT NULL COMMENT '配置键，点分命名：adult.tags / app.notice',
    config_value JSON         NOT NULL COMMENT '任意 JSON：标量 / 数组 / 对象',
    note         VARCHAR(255) NULL COMMENT '给人看的说明：这个键是干什么的',
    updated_at   DATETIME(3)  NOT NULL COMMENT '同时充当配置版本（MAX 即当前版本）',
    PRIMARY KEY (config_key)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT '运行期可改配置；写入只走 /internal/app/config';

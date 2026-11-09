-- 信息卡四字段（#564 / docs/relation-algorithm.md §5.x 信息卡）
--
-- 首站 `content_facts` 里有四条「作品级事实」：官方网站 / 放送开始 / 播放结束 / 企画。
-- 它们和系列一样，是「作品详情页才需要、且只有数据集通道拿得到」的东西——
-- 站点 REST 通道没有这些概念，一次常规站点同步如果乱覆盖，会把数据集导进来的信息抹掉。
--
-- 所以落库口径严格照 series_key（V37）那套先例：
--   1. 四个显式列，不是通用 map；publisher 侧做「中文键 → 字段」的映射。
--   2. 只有数据集通道会给；省略 / null = 本次没拿到，**不动**库里已有值（不覆盖、不置空）。
--   3. 写入走独立的 `WorkRepository.updateInfos`（动态 SET，只写非 null 的字段），
--      `WorkRecord` 读模型根本不带这几个字段——避免改 record 元数炸一票测试，
--      也和系列字段不进 `WorkMerger` 同一理由。
--   4. 详情展示用的 `infos` 响应数组本 PR 不动：数据真正流转依赖独立的 ETL（work_facts），
--      在那之前库里是空，空是预期不是 bug（pyxz0 已确认）。
--
-- 长度与首站 content_facts 实测取值对齐：
--   official_url  1024 —— 与 work.source_url 同列宽，超长按「没拿到」丢弃（不截断半截地址）。
--   broadcast_start / broadcast_end 32 —— 来源原值（如 2024-01-05），不做日期解析；32 留足余量。
--   planning      500 —— 企画可能是多人顿号串（原值），500 够长。
-- 四列全部可空、不加索引、不加 DEFAULT：它们是低频展示字段，不进列表/筛选的访问路径。

ALTER TABLE work
    ADD COLUMN official_url    VARCHAR(1024) NULL COMMENT '官方网站（content_facts:官方网站）；NULL=来源未提供',
    ADD COLUMN broadcast_start VARCHAR(32)   NULL COMMENT '放送开始（来源原值，不做日期解析）；NULL=未提供',
    ADD COLUMN broadcast_end   VARCHAR(32)   NULL COMMENT '播放结束（来源原值）；NULL=未提供',
    ADD COLUMN planning        VARCHAR(500)  NULL COMMENT '企画（来源原值，可能是多人顿号串）；NULL=未提供';

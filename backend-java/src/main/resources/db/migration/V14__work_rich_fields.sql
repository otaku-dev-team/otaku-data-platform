-- 详情扩 4 个富字段（Issue #250，契约 openapi.yaml Work / ImportItem）
--   - title_original：原名，最长 500；
--   - aliases：别名 JSON 数组文本，三态（NULL 未提供 / [] 明确没有 / 非空）；
--   - media：来源原值（TV / OVA / 剧场版…），**不做跨源枚举归一**，最长 64；
--   - episodes：话数，1–10000；0 与「未提供」含义不同，越界在导入层整条拒收（INVALID_EPISODES）。
--
-- aliases 不建关联表：它是展示用的短列表（实测中位 1–3 个），没有按别名反查的需求；
-- 将来真要做别名搜索时再单独建索引表，不提前摊开。

ALTER TABLE work
    ADD COLUMN title_original VARCHAR(500) NULL COMMENT '原名；NULL = 来源未提供',
    ADD COLUMN aliases        TEXT         NULL COMMENT '别名 JSON 数组文本；NULL 未提供 / [] 明确没有',
    ADD COLUMN media          VARCHAR(64)  NULL COMMENT '媒介形态，来源原值，不做枚举归一',
    ADD COLUMN episodes       INT          NULL COMMENT '话数 1-10000；NULL = 未提供（0 无意义，导入层拒收）'
;

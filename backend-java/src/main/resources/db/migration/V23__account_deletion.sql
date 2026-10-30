-- 用户注销（#240 B2c⑤，口径见 docs/ugc-retention-proposal.md §6）
--
-- 语义（zm 2026-10-30 定）：默认**匿名化保留**——评论行不动，展示时作者显示「已注销用户」，
-- 楼层不塌；物理删留一个默认关闭的开关，最终以站点/法务口径为准。
--
-- 为什么用单独一列而不是只看 status：
--   status='disabled' 现在还表示「站主禁用」（可恢复）。注销是用户主动、且不该被站主恢复，
--   两者必须能区分——deleted_at 非空 = 用户自己注销的。
ALTER TABLE app_user
    ADD COLUMN deleted_at DATETIME(3) NULL
        COMMENT '用户注销时间；NULL = 未注销。非空时 status 同时置 disabled，展示层匿名化';

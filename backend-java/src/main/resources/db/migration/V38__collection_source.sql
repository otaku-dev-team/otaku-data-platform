-- 收藏来源（#506）：区分「用户自己点的」和「冷启动漏斗种下的」。
--
-- 为什么要这一列：漏斗（#492）把标注答案直接写进 collection，一次种几十上百条。
-- 如果种子和真实操作长得一样，两件事都做不了：
--   1. 用户改过的状态，下次重跑漏斗会被再盖回去（#506 要求「真实操作始终优先于种子」）；
--   2. 事后无法判断「这个人真看过 100 部」还是「他答了一套题」。
--
-- 默认 'user' 让存量行与所有老客户端保持原语义：不传 source 就是用户操作。
ALTER TABLE collection
    ADD COLUMN source VARCHAR(16) NOT NULL DEFAULT 'user'
        COMMENT 'user = 用户操作；quiz = 冷启动漏斗种子（#506）' AFTER status;

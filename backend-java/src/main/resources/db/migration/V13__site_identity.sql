-- 阶段 2 账号绑定：站点身份映射 + 站点令牌哈希
-- 与 docs/identity-linkup-contract.md §2 / §3（契约 #147）及 Issue #242 对应：
--   - 平台侧做「令牌交换代理」，用站点 access_token 换出的用户身份映射到 app_user；
--   - identity_source + external_user_id 唯一键构成映射锚：站点 external_user_id 稳定不变，
--     重登映射恒定；NULL = 平台账号，现状语义完全不变；
--   - 站点令牌只存哈希（契约 §7：与站点「令牌只存哈希」对齐，平台侧泄库也不裸奔）；
--   - nickname / avatar_url 不落库（契约 §7：仅客户端展示，不回写、不再分发）；
--   - ticket 一次性 120 秒，平台后端不落 ticket。

ALTER TABLE app_user
    ADD COLUMN identity_source VARCHAR(32) NULL
        COMMENT '身份来源，如 otaku_site；NULL = 平台账号（既有账号语义不变）',
    ADD COLUMN external_user_id VARCHAR(64) NULL
        COMMENT '来源站用户主键，与 identity_source 共同构成映射',
    ADD COLUMN site_token_hash CHAR(64) NULL
        COMMENT 'SHA-256(站点 access_token)；库里不存原始令牌',
    ADD COLUMN site_token_expires_at DATETIME(3) NULL
        COMMENT '站点令牌到期时间（站点侧固定 3600 秒）',
    ADD UNIQUE KEY uk_identity (identity_source, external_user_id)
;

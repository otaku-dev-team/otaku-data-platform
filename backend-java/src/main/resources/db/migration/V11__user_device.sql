-- 推送设备令牌登记（W1.3b 方案 §4.4）。
--
-- 为什么单独一张表而不是挂在 user_session 上：会话是「一次登录一行、退出即撤销」，
-- 令牌是「一块安装一个、跨登录存在」。混在一起两个方向都错——退出登录后令牌跟着被撤销
-- （下次登录前收不到），或者为了保住令牌而不撤销会话（撤销语义被污染）。
--
-- ⚠️ token 列视同凭据：不进日志、不回显（GET 列表不返回它）。
--
-- 唯一键的设计是这份表的核心：
--   uk_user_device (user_id, device_id) —— upsert 键。**不是 token**：
--     token 会轮换，device_id 不会；用 token 当键会导致轮换时产生新行、旧行残留。
--   uk_device_token (token) —— token 全局唯一，这是「跨账号转移」得以实现的基础：
--     同一台设备换账号登录时，新账号注册同一个 token，
--     旧账号那条必须失效——否则前一个用户退出后，这台设备仍会收到他的推送，
--     而通知会直接显示在锁屏上。与收藏缓存按账号分桶是同一类问题，后果更直接。

CREATE TABLE IF NOT EXISTS user_device
(
    id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    user_id     BIGINT UNSIGNED NOT NULL COMMENT 'app_user.id',
    device_id   VARCHAR(64)     NOT NULL COMMENT '客户端生成的安装级标识；重装后变',
    platform    VARCHAR(16)     NOT NULL COMMENT 'android | windows | ios',
    provider    VARCHAR(16)     NOT NULL COMMENT 'fcm | apns',
    token       VARCHAR(512)    NOT NULL COMMENT 'provider 下发的令牌，视同凭据',
    app_version VARCHAR(32)     NULL,
    enabled     TINYINT(1)      NOT NULL DEFAULT 1,
    created_at  DATETIME(3)     NOT NULL,
    updated_at  DATETIME(3)     NOT NULL,
    disabled_at DATETIME(3)     NULL COMMENT 'provider 判失效的时间；不删除，保留排查',
    PRIMARY KEY (id),
    UNIQUE KEY uk_user_device (user_id, device_id),
    UNIQUE KEY uk_device_token (token),
    KEY idx_device_user (user_id, enabled),
    CONSTRAINT fk_device_user FOREIGN KEY (user_id) REFERENCES app_user (id)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT '推送令牌按安装登记，跨登录存在';

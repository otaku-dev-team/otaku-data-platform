-- 阶段 2：账号、多设备会话、个人收藏与观看状态
-- 与 docs/otaku-project-plan-v2.md 第 2.2 / 5.2 节对应：
--   - 账号由 Java 统一管理；每台设备一个会话，一端登录不踢另一端
--   - 收藏按 user_id + work_id 唯一；取消收藏同时删除状态
--   - 个人数据与作品同步完全分离：work 表的同步绝不触碰这三张表

CREATE TABLE IF NOT EXISTS app_user
(
    id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    user_id       VARCHAR(32)     NOT NULL COMMENT '对外用户标识，不透明，不暴露自增 id',
    username      VARCHAR(32)     NOT NULL COMMENT '登录名；collation 不区分大小写，同名不同大小写视为重复',
    password_hash VARCHAR(100)    NOT NULL COMMENT 'BCrypt 摘要，永不存明文',
    created_at    DATETIME(3)     NOT NULL,
    updated_at    DATETIME(3)     NOT NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uk_user_id (user_id),
    UNIQUE KEY uk_username (username)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT '平台账号；与接入网站的原生账号无关';

CREATE TABLE IF NOT EXISTS user_session
(
    id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    token_hash   CHAR(64)        NOT NULL COMMENT 'SHA-256(token)；库里不存原始令牌，泄库也无法直接冒用',
    user_id      BIGINT UNSIGNED NOT NULL COMMENT 'app_user.id',
    device_label VARCHAR(64)     NULL COMMENT '客户端自报的设备标识，仅用于展示与排查',
    created_at   DATETIME(3)     NOT NULL,
    last_seen_at DATETIME(3)     NULL,
    expires_at   DATETIME(3)     NOT NULL,
    revoked_at   DATETIME(3)     NULL COMMENT '退出登录只置本行，其他设备会话不受影响',
    PRIMARY KEY (id),
    UNIQUE KEY uk_token_hash (token_hash),
    KEY idx_session_user (user_id, revoked_at),
    CONSTRAINT fk_session_user FOREIGN KEY (user_id) REFERENCES app_user (id)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT '一登录一行，支持多设备并存';

CREATE TABLE IF NOT EXISTS collection
(
    id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    user_id    BIGINT UNSIGNED NOT NULL COMMENT 'app_user.id',
    work_id    VARCHAR(32)     NOT NULL COMMENT 'work.work_id（不建外键，避免作品同步与个人数据耦合）',
    status     VARCHAR(16)     NULL COMMENT 'want / watching / watched；收藏后可为空',
    created_at DATETIME(3)     NOT NULL,
    updated_at DATETIME(3)     NOT NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uk_collection_user_work (user_id, work_id),
    KEY idx_collection_user_updated (user_id, updated_at),
    CONSTRAINT fk_collection_user FOREIGN KEY (user_id) REFERENCES app_user (id)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT '个人收藏；取消收藏即删行，状态随之消失';

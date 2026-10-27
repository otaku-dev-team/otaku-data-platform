-- 站主运营后台（Issue #144，依据 docs/site-owner-console-proposal.md §3–§4、§8）
--
-- 边界（红线，不可让步）：
--   * 站主只能看/管**自己这一个站点**；站点身份只从登录态推导，**不接受请求参数**；
--   * 站点接入与站点配置**不在后台暴露**：site / site_source / 站主名单只由 /internal/** 维护（平台侧）；
--   * 「禁用用户」= 禁用该用户在本站**客户端**的登录（平台侧会话失效），
--     **不回写网站账号**（网站账号的存废是网站自己的事，见 §4.2）。
--
-- 为什么单独建 site 表，而不拿 work.source 当站点：
--   work.source 是「数据来源标识」，一个站点可能有多个来源（自有数据 + 第三方库）。
--   隔离的维度是**站点**，所以这里把 source 收敛到 site_source，
--   并用 uk_site_source 保证「一个 source 只属于一个站点」——越权判断才有唯一依据。
--   若允许一个 source 属于两个站点，A 站的作品就会同时出现在 B 站后台，任何过滤都说不清。

CREATE TABLE IF NOT EXISTS site
(
    site_key     VARCHAR(32)  NOT NULL COMMENT '站点键，如首站的 site_key；对外不透明化处理由调用方决定',
    display_name VARCHAR(128) NOT NULL COMMENT '站主后台里显示的名字',
    status       VARCHAR(16)  NOT NULL DEFAULT 'active' COMMENT 'active / suspended；suspended 时后台整体 403',
    created_at   DATETIME(3)  NOT NULL,
    updated_at   DATETIME(3)  NOT NULL,
    PRIMARY KEY (site_key)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT '接入站点。只由 /internal/** 维护，后台无任何写入入口';

CREATE TABLE IF NOT EXISTS site_source
(
    site_key   VARCHAR(32) NOT NULL,
    source     VARCHAR(64) NOT NULL COMMENT '与 work.source / import_batch.source 同值',
    created_at DATETIME(3) NOT NULL,
    PRIMARY KEY (site_key, source),
    -- 一个来源只能属于一个站点：这是数据隔离的唯一依据，不能被"多对多"破坏
    UNIQUE KEY uk_site_source (source),
    CONSTRAINT fk_site_source_site FOREIGN KEY (site_key) REFERENCES site (site_key)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT '站点 → 数据来源映射；后台所有作品/同步查询都按它过滤';

-- 站主账号（过渡态：平台自建 + 站主名单校验，见提案 §4.1 选项 C）
--
-- identity_source / external_user_id 是为「切到网站账号」预留的映射位：
-- 网站 OAuth（#147）就绪后，同一张表新增 identity_source='site_oauth' 的行，
-- password_hash 留空，登录改走站点授权；后台接口与前端不需要改动。
-- 现在就留列，比将来改表 + 改鉴权链更便宜，也不会出现"两套账号各记一份"的中间态。
CREATE TABLE IF NOT EXISTS site_admin
(
    id               BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    admin_id         VARCHAR(32)     NOT NULL COMMENT '对外标识，G- 前缀，不暴露自增 id',
    site_key         VARCHAR(32)     NOT NULL COMMENT '所属站点；站主的一切查询都以它为界',
    username         VARCHAR(64)     NOT NULL COMMENT '登录名，全局唯一（站主登录时不需要先选站点）',
    password_hash    VARCHAR(100)    NULL COMMENT 'BCrypt；identity_source=site_oauth 时为空',
    display_name     VARCHAR(64)     NULL,
    identity_source  VARCHAR(16)     NOT NULL DEFAULT 'platform' COMMENT 'platform / site_oauth',
    external_user_id VARCHAR(128)    NULL COMMENT '网站侧用户标识，接入网站账号后写入',
    status           VARCHAR(16)     NOT NULL DEFAULT 'active' COMMENT 'active / disabled',
    created_at       DATETIME(3)     NOT NULL,
    updated_at       DATETIME(3)     NOT NULL,
    last_login_at    DATETIME(3)     NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uk_admin_id (admin_id),
    UNIQUE KEY uk_admin_username (username),
    UNIQUE KEY uk_admin_external (identity_source, external_user_id),
    KEY idx_admin_site (site_key, status),
    CONSTRAINT fk_admin_site FOREIGN KEY (site_key) REFERENCES site (site_key)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT '站主名单：名单内的人才能进后台（提案 §4.1）';

CREATE TABLE IF NOT EXISTS site_admin_session
(
    id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    token_hash    CHAR(64)        NOT NULL COMMENT 'SHA-256(token)；库里不存原始令牌',
    site_admin_id BIGINT UNSIGNED NOT NULL,
    device_label  VARCHAR(64)     NULL,
    created_at    DATETIME(3)     NOT NULL,
    last_seen_at  DATETIME(3)     NULL,
    expires_at    DATETIME(3)     NOT NULL,
    revoked_at    DATETIME(3)     NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uk_admin_token (token_hash),
    KEY idx_admin_session (site_admin_id, revoked_at),
    CONSTRAINT fk_admin_session_admin FOREIGN KEY (site_admin_id) REFERENCES site_admin (id)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT '后台会话；与客户端 user_session 分开，两套凭据互不通用';

-- 客户端账号归属站点与状态。
--
-- site_key 可空：历史账号（本迁移之前的行）没有归属。**空值一律不出现在任何站主后台**，
-- 也不允许任何站主禁用——fail-closed：宁可站主看不到，也不能让 A 站看到 B 站的账号。
-- 新账号由 /internal/accounts 建号时显式带上 site_key。
ALTER TABLE app_user
    ADD COLUMN site_key          VARCHAR(32) NULL COMMENT '归属站点；NULL = 未归属，任何站主后台都看不到',
    ADD COLUMN status            VARCHAR(16) NOT NULL DEFAULT 'active' COMMENT 'active / disabled；disabled = 不能登录客户端，网站账号不受影响',
    ADD COLUMN status_changed_at DATETIME(3) NULL COMMENT '最近一次禁用/解禁时间；后台列表要显示"什么时候被封的"',
    ADD KEY idx_user_site_status (site_key, status),
    ADD CONSTRAINT fk_user_site FOREIGN KEY (site_key) REFERENCES site (site_key);

-- 同步状态要按站点过滤：先用 source 圈范围，再按时间取最近几次。
ALTER TABLE import_batch
    ADD KEY idx_batch_source (source, finished_at);

-- 客户端安装级使用统计（「有多少人在用」的唯一准确口径）。
--
-- 为什么需要：此前能数人的只有 app_user，但**浏览完全匿名**——
-- 不登录也能看列表、详情、档期，所以「注册账号数」既不是装机量也不是活跃数
-- （2026-10-31 实测：库里 2 个账号，其中一个还是控制台演示号）。
-- accesslog 能按 IP 估算，但 NAT 会把一群人压成一个、换网会把一个人拆成两个。
-- 这个表补的就是这一层：一次安装一行，跨启动稳定。
--
-- 隐私边界（**这几条是这份 schema 的核心，不是可选项**）：
--   1. install_id 由客户端本地生成，是随机 UUID v4，不参与任何硬件指纹
--      （不采 IMEI / OAID / AndroidID / MAC / 序列号）；
--   2. **不存 IP、不存设备型号、不关联 user_id**。存了就不再是匿名数据，
--      而「匿名装机数」能回答的问题，比「谁在用什么」多不了多少、合规负担差一个量级；
--   3. 只记「首次见到 / 最近见到 / 见过几次 / 版本 / 平台」五件事。
--      答得了「多少装机、多少日活、版本分布」，答不了「谁」——后者我们不要。
--
-- 与 user_device 的区别（别合并）：
--   user_device 是**推送令牌**，必须绑定 user_id（否则锁屏上会收到前一个用户的推送），
--   一个账号一台设备一行；这里不绑定账号，重装 App 会变成新的一行。
--   两者的生命周期与删除语义完全不同，合并任何一个方向都是错的。

CREATE TABLE IF NOT EXISTS client_install
(
    install_id    CHAR(36)     NOT NULL COMMENT '客户端生成的随机 UUID v4；重装后变',
    first_seen_at DATETIME(3)  NOT NULL COMMENT '第一次心跳；= 装机时间（近似）',
    last_seen_at  DATETIME(3)  NOT NULL COMMENT '最近一次心跳',
    ping_count    INT UNSIGNED NOT NULL DEFAULT 1 COMMENT '累计心跳次数；可粗判"装了就删"',
    app_version   VARCHAR(32)  NULL COMMENT '最近一次上报的 versionName，如 1.1.4',
    platform      VARCHAR(16)  NULL COMMENT 'android | windows | ios | …',
    PRIMARY KEY (install_id),
    -- 算「近 7 天 / 近 30 天活跃」走这个索引，别全表扫
    KEY idx_install_last_seen (last_seen_at)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT '安装级匿名统计；不含 IP / 设备指纹 / 账号';

-- 日活要的是「每天出现过哪些安装」，只看 client_install.last_seen_at 只能得到
-- 当前状态、拿不到历史曲线，所以另存一天的明细。
--
-- 为什么按天一行而不是每次心跳一行：后者一天就能涨到几十万行，
-- 而「日活」这个指标只关心「这天来没来」——重复心跳是噪声。
-- 代价是**同日多次心跳只留一行**，想知道频次看 client_install.ping_count。
CREATE TABLE IF NOT EXISTS client_active_day
(
    install_id CHAR(36) NOT NULL,
    day        DATE     NOT NULL COMMENT '服务器本地日期（容器 TZ=Asia/Shanghai）',
    PRIMARY KEY (install_id, day),
    KEY idx_active_day (day)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT '按天去重的活跃安装；日活 = COUNT(*) WHERE day = ?';

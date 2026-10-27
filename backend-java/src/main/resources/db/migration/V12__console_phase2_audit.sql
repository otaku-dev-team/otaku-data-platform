-- 站主后台二期（Issue #144）：站主名单自助维护 + 用户详情/收藏。
--
-- 为什么这一版才建审计表：提案 §4.3 要求「站主名单变更（新增/移除站主）要有据可查」。
-- 首版的名单变更只有平台侧 /internal/** 在动，操作者只有我们自己，日志足够；
-- 二期把「增删站主」开放给站主后，**同一站点内多个管理员互相操作**，
-- 出问题时第一句话一定是「是谁停的、什么时候」——没有表就只能翻容器日志，
-- 而容器日志默认只留几天。
--
-- 不加外键：审计必须比被审计的行活得久（站主被停用/改名后记录仍要能读）。
CREATE TABLE IF NOT EXISTS console_audit
(
    id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    site_key       VARCHAR(32)     NOT NULL COMMENT '动作发生的站点；查询永远按它过滤',
    actor_admin_id VARCHAR(32)     NOT NULL COMMENT '发起人 admin_id（G- 前缀）',
    action         VARCHAR(32)     NOT NULL COMMENT 'admin.create / admin.disable / admin.enable / user.disable / user.enable',
    target_type    VARCHAR(16)     NOT NULL COMMENT 'admin / user',
    target_id      VARCHAR(64)     NOT NULL COMMENT '目标 admin_id 或 user_id',
    detail         VARCHAR(512)    NULL COMMENT '补充说明（如禁用原因、新建站主的用户名）',
    created_at     DATETIME(3)     NOT NULL,
    PRIMARY KEY (id),
    KEY idx_console_audit_site (site_key, created_at),
    KEY idx_console_audit_target (target_type, target_id, created_at)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT '站主后台操作留痕；只写不改，无后台读接口（平台侧查库/导出）';

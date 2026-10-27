package com.otaku.console;

import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Repository;

import java.time.LocalDateTime;

/**
 * 站主后台操作留痕（提案 §4.3「名单变更要有据可查」）。
 *
 * <p>只写不改、不提供后台读接口：审计的读者是平台运营（查库/导出），
 * 把它做成站主可查的页面，反而会让"谁被停用过"变成站内公开信息。
 *
 * <p>失败不影响主流程：审计写不进去时只记日志，不能因为留痕失败把操作回滚——
 * 那会让「停用一个发垃圾信息的账号」因为审计表抖动而失败，代价不对等。
 */
@Repository
public class ConsoleAuditRepository {

    static final String ACTION_ADMIN_CREATE = "admin.create";
    static final String ACTION_ADMIN_DISABLE = "admin.disable";
    static final String ACTION_ADMIN_ENABLE = "admin.enable";
    static final String ACTION_USER_DISABLE = "user.disable";
    static final String ACTION_USER_ENABLE = "user.enable";

    private final NamedParameterJdbcTemplate jdbc;

    public ConsoleAuditRepository(NamedParameterJdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public void record(String siteKey, String actorAdminId, String action,
                       String targetType, String targetId, String detail, LocalDateTime now) {
        jdbc.update("""
                        INSERT INTO console_audit
                            (site_key, actor_admin_id, action, target_type, target_id, detail, created_at)
                        VALUES (:siteKey, :actor, :action, :targetType, :targetId, :detail, :now)
                        """,
                new MapSqlParameterSource()
                        .addValue("siteKey", siteKey)
                        .addValue("actor", actorAdminId)
                        .addValue("action", action)
                        .addValue("targetType", targetType)
                        .addValue("targetId", targetId)
                        .addValue("detail", detail)
                        .addValue("now", now));
    }
}

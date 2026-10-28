package com.otaku.auth;

import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Repository;

import java.time.LocalDateTime;
import java.util.List;
import java.util.Optional;

/**
 * 站点身份映射的读写（契约 identity-linkup-contract.md §3，Issue #242）。
 *
 * <p>刻意**不复用 {@link com.otaku.user.UserRecord}**：它有 9 个字段、多处构造点，
 * 为了 4 个可空列把每处构造都改一遍不值得；这里只查/写本特性关心的列，
 * 用户全量资料仍走 {@link com.otaku.user.UserRepository}。
 *
 * <p>唯一键 {@code uk_identity (identity_source, external_user_id)}：
 * MySQL 唯一键对 NULL 不去重，所以既有平台账号（两列全 NULL）完全不受影响。
 */
@Repository
public class SiteIdentityRepository {

    private final NamedParameterJdbcTemplate jdbc;

    public SiteIdentityRepository(NamedParameterJdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    /** 按映射锚找账号；返回 userPk 与账号状态（禁用判断在服务层，与口令登录同口径）。 */
    public Optional<SiteIdentityMapping> findMapping(String identitySource, String externalUserId) {
        List<SiteIdentityMapping> rows = jdbc.query("""
                        SELECT id, status FROM app_user
                         WHERE identity_source = :source AND external_user_id = :externalUserId
                        """,
                new MapSqlParameterSource()
                        .addValue("source", identitySource)
                        .addValue("externalUserId", externalUserId),
                (rs, rowNum) -> new SiteIdentityMapping(rs.getLong("id"), rs.getString("status")));
        return rows.stream().findFirst();
    }

    /**
     * 新建站点映射账号。口令摘要用一个不可登录的随机值占位
     * （列 NOT NULL；站点账号本无口令，随机值让口令登录永远不可能命中）。
     *
     * @return 新账号的自增 id
     */
    public long insertSiteUser(String userId, String username, String passwordHash,
                               String identitySource, String externalUserId,
                               String siteTokenHash, LocalDateTime siteTokenExpiresAt,
                               LocalDateTime now) {
        jdbc.update("""
                        INSERT INTO app_user (user_id, username, password_hash, status,
                                              identity_source, external_user_id,
                                              site_token_hash, site_token_expires_at,
                                              created_at, updated_at)
                        VALUES (:userId, :username, :passwordHash, 'active',
                                :identitySource, :externalUserId,
                                :siteTokenHash, :siteTokenExpiresAt,
                                :now, :now)
                        """,
                new MapSqlParameterSource()
                        .addValue("userId", userId)
                        .addValue("username", username)
                        .addValue("passwordHash", passwordHash)
                        .addValue("identitySource", identitySource)
                        .addValue("externalUserId", externalUserId)
                        .addValue("siteTokenHash", siteTokenHash)
                        .addValue("siteTokenExpiresAt", siteTokenExpiresAt)
                        .addValue("now", now));
        Long id = jdbc.queryForObject(
                "SELECT id FROM app_user WHERE identity_source = :source AND external_user_id = :externalUserId",
                new MapSqlParameterSource()
                        .addValue("source", identitySource)
                        .addValue("externalUserId", externalUserId), Long.class);
        if (id == null) {
            throw new IllegalStateException("站点映射账号插入后读取失败");
        }
        return id;
    }

    /** 登录即刷新站点令牌哈希（旧令牌作废由站点侧 revoke 保证，我们只留最新一份）。 */
    public void updateSiteToken(long userPk, String siteTokenHash,
                                LocalDateTime siteTokenExpiresAt, LocalDateTime now) {
        jdbc.update("""
                        UPDATE app_user
                           SET site_token_hash = :siteTokenHash,
                               site_token_expires_at = :siteTokenExpiresAt,
                               updated_at = :now
                         WHERE id = :id
                        """,
                new MapSqlParameterSource()
                        .addValue("id", userPk)
                        .addValue("siteTokenHash", siteTokenHash)
                        .addValue("siteTokenExpiresAt", siteTokenExpiresAt)
                        .addValue("now", now));
    }

    /** 映射行：账号主键 + 状态。 */
    public record SiteIdentityMapping(long userPk, String status) {
        public boolean active() {
            return !"disabled".equals(status);
        }
    }
}

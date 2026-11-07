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

    /** 账号的身份来源；空 = 平台账号（`/api/auth/me` 用）。 */
    public Optional<String> findIdentitySource(long userPk) {
        List<String> rows = jdbc.query("""
                        SELECT identity_source FROM app_user
                         WHERE id = :id AND identity_source IS NOT NULL
                        """,
                new MapSqlParameterSource("id", userPk),
                (rs, rowNum) -> rs.getString("identity_source"));
        return rows.stream().findFirst();
    }

    /**
     * 找「已断开但保留」的账号：`identity_source` 已置空、`external_user_id` 还在。
     *
     * <p>重新授权时据此把同一个站点身份接回**原账号**——否则「断开一次再连」会新建一个
     * 空账号，用户看到的是「我的收藏被删了」。`ORDER BY id LIMIT 1` 只作兜底排序：
     * 首站 1:1，`external_user_id` 由站点保证唯一；将来做 N:M 时必须改成
     * `(identity_source, external_user_id)` 的墓碑表，不能继续靠这一列。
     */
    public Optional<SiteIdentityMapping> findUnlinked(String externalUserId) {
        List<SiteIdentityMapping> rows = jdbc.query("""
                        SELECT id, status FROM app_user
                         WHERE identity_source IS NULL AND external_user_id = :externalUserId
                         ORDER BY id
                         LIMIT 1
                        """,
                new MapSqlParameterSource("externalUserId", externalUserId),
                (rs, rowNum) -> new SiteIdentityMapping(rs.getLong("id"), rs.getString("status")));
        return rows.stream().findFirst();
    }

    /**
     * 断开站点连接：清「身份 + 令牌」，**保留 `external_user_id` 与账号本身**。
     *
     * <p>保留 `external_user_id` 是重连的锚点（见 {@link #findUnlinked}）；
     * 账号留着是因为它是用户全部收藏/浏览/评论的宿主，删行等于删数据。
     * 真要把数据一并清掉，走 `DELETE /api/me`（那条路会匿名化保留 UGC 再禁用账号）。
     *
     * @return 受影响行数；0 表示调用时已经断开了（并发下第二次调用）
     */
    public int unlink(long userPk, LocalDateTime now) {
        return jdbc.update("""
                        UPDATE app_user
                           SET identity_source = NULL,
                               site_token_hash = NULL,
                               site_token_expires_at = NULL,
                               updated_at = :now
                         WHERE id = :id AND identity_source IS NOT NULL
                        """,
                new MapSqlParameterSource()
                        .addValue("id", userPk)
                        .addValue("now", now));
    }

    /**
     * 把已断开的账号接回站点身份（重新授权时用）。
     *
     * <p>`WHERE identity_source IS NULL` 是并发保护：同一身份的两个请求只有一个能接回，
     * 另一个走 {@link #findMapping} 拿到同一行，结果一致。
     */
    public int relink(long userPk, String identitySource, String siteTokenHash,
                      LocalDateTime siteTokenExpiresAt, LocalDateTime now) {
        return jdbc.update("""
                        UPDATE app_user
                           SET identity_source = :identitySource,
                               site_token_hash = :siteTokenHash,
                               site_token_expires_at = :siteTokenExpiresAt,
                               updated_at = :now
                         WHERE id = :id AND identity_source IS NULL
                        """,
                new MapSqlParameterSource()
                        .addValue("id", userPk)
                        .addValue("identitySource", identitySource)
                        .addValue("siteTokenHash", siteTokenHash)
                        .addValue("siteTokenExpiresAt", siteTokenExpiresAt)
                        .addValue("now", now));
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

package com.otaku.console;

import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Repository;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDateTime;
import java.util.List;
import java.util.Optional;

/**
 * 站点与「站点 → 数据来源」映射。
 *
 * <p><b>只读仓储</b>：写入只发生在 {@link InternalSiteController}（/internal/**，平台侧）。
 * 后台没有任何调用点能改站点——这是提案 §2.2 的红线「站点接入与配置不开放」在代码层的落点：
 * 不是靠"界面上不放出按钮"，而是站主能走到的代码路径里根本没有写站点的方法。
 */
@Repository
public class SiteRepository {

    private static final RowMapper<SiteRecord> MAPPER = (rs, rowNum) -> new SiteRecord(
            rs.getString("site_key"),
            rs.getString("display_name"),
            rs.getString("status"),
            rs.getObject("created_at", LocalDateTime.class),
            rs.getObject("updated_at", LocalDateTime.class));

    private final NamedParameterJdbcTemplate jdbc;

    public SiteRepository(NamedParameterJdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public Optional<SiteRecord> find(String siteKey) {
        return jdbc.query("""
                        SELECT site_key, display_name, status, created_at, updated_at
                          FROM site WHERE site_key = :siteKey
                        """,
                new MapSqlParameterSource("siteKey", siteKey), MAPPER)
                .stream().findFirst();
    }

    /**
     * 站点名下的数据来源（work.source / import_batch.source 的取值）。
     *
     * <p>返回空列表表示"这个站点还没配来源"——后台会显示 0 个作品、无同步记录，
     * 而不是退化成「不加过滤、看全库」。后者是这类后台最常见的越权来源。
     */
    public List<String> findSources(String siteKey) {
        return jdbc.queryForList("""
                        SELECT source FROM site_source WHERE site_key = :siteKey ORDER BY source
                        """,
                new MapSqlParameterSource("siteKey", siteKey), String.class);
    }

    @Transactional
    public void create(SiteRecord site, List<String> sources) {
        jdbc.update("""
                        INSERT INTO site (site_key, display_name, status, created_at, updated_at)
                        VALUES (:siteKey, :displayName, :status, :createdAt, :updatedAt)
                        """,
                new MapSqlParameterSource()
                        .addValue("siteKey", site.siteKey())
                        .addValue("displayName", site.displayName())
                        .addValue("status", site.status())
                        .addValue("createdAt", site.createdAt())
                        .addValue("updatedAt", site.updatedAt()));
        for (String source : sources) {
            jdbc.update("""
                            INSERT INTO site_source (site_key, source, created_at)
                            VALUES (:siteKey, :source, :now)
                            """,
                    new MapSqlParameterSource()
                            .addValue("siteKey", site.siteKey())
                            .addValue("source", source)
                            .addValue("now", site.createdAt()));
        }
    }
}

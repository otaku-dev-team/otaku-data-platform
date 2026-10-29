package com.otaku.ugc;

import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Repository;

import java.time.LocalDateTime;
import java.util.List;
import java.util.Optional;

/**
 * 站点的 UGC 开关（{@code site.ugc_enabled}）。
 *
 * <p>为什么单独一个仓储、而不是加进 {@code SiteRepository}：那个类刻意是**只读**的
 * （站点接入与配置只能由平台侧 {@code /internal/**} 改）。UGC 开关恰好相反——
 * 它是站主在后台自己开的开关，属于「站主可自管」的范畴。
 * 两者混在一起，下次有人要给后台加站点写接口就有了现成的入口，红线会被慢慢磨掉。
 */
@Repository
public class UgcSettingsRepository {

    private final NamedParameterJdbcTemplate jdbc;

    public UgcSettingsRepository(NamedParameterJdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    /** 站点不存在或没开 → false（fail-closed：读不到就当作没开）。 */
    public boolean isEnabled(String siteKey) {
        List<Boolean> rows = jdbc.queryForList(
                "SELECT ugc_enabled FROM site WHERE site_key = :siteKey",
                new MapSqlParameterSource("siteKey", siteKey), Boolean.class);
        return rows.stream().findFirst().orElse(false);
    }

    /**
     * 审核模式：post（先发后审，默认）/ pre（先审后发）。
     * 读不到站点时按 post 处理——它不会把评论藏起来，最坏是「多露了一条」，好过整站评论消失。
     */
    public String moderationMode(String siteKey) {
        List<String> rows = jdbc.queryForList(
                "SELECT ugc_moderation FROM site WHERE site_key = :siteKey",
                new MapSqlParameterSource("siteKey", siteKey), String.class);
        return rows.stream().findFirst().filter("pre"::equals).orElse("post");
    }

    public void setModerationMode(String siteKey, String mode, LocalDateTime now) {
        jdbc.update("UPDATE site SET ugc_moderation = :mode, updated_at = :now WHERE site_key = :siteKey",
                new MapSqlParameterSource()
                        .addValue("siteKey", siteKey)
                        .addValue("mode", mode)
                        .addValue("now", now));
    }

    public void setEnabled(String siteKey, boolean enabled, LocalDateTime now) {
        jdbc.update("""
                UPDATE site SET ugc_enabled = :enabled, updated_at = :now WHERE site_key = :siteKey
                """, new MapSqlParameterSource()
                .addValue("siteKey", siteKey)
                .addValue("enabled", enabled)
                .addValue("now", now));
    }

    /**
     * 当前实例服务的站点。
     *
     * <p>客户端要问「这个站开没开社区」，但客户端请求不带站点标识（一个部署服务一个站）。
     * 所以：**恰好一个 active 站点**时才返回它；零个或多个都返回 empty，由调用方按「未开启」
     * 处理（fail-closed）。多站部署时正确做法是给实例配 {@code OTAKU_SITE_KEY}，那是将来的事，
     * 现在不猜。
     */
    public Optional<String> singleActiveSite() {
        List<String> rows = jdbc.queryForList(
                "SELECT site_key FROM site WHERE status = 'active' LIMIT 2", new MapSqlParameterSource(),
                String.class);
        return rows.size() == 1 ? Optional.of(rows.get(0)) : Optional.empty();
    }
}

package com.otaku.work;

import com.otaku.work.dto.TagDtos;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Repository;

import java.util.List;

/**
 * 标签词表查询。
 *
 * <p>数据源与筛选用的是同一张 {@code work_tag}（导入链路维护），不另存词表白名单：
 * 来源站改名后旧词自然消失，不会出现「词表里有、筛出来是空」的幽灵标签。
 *
 * <p>{@code GROUP BY tag} 会走 {@code PRIMARY KEY (tag, work_ref)} 的松散索引扫描
 * （MySQL 对 "GROUP BY 索引前缀 + COUNT(*)" 会走 loose index scan），
 * 不需要回表；词表规模约 500 条/类，一次取完没有压力。
 */
@Repository
public class TagRepository {

    private static final RowMapper<TagDtos.TagItem> MAPPER = (rs, rowNum) ->
            new TagDtos.TagItem(rs.getString("name"), rs.getLong("work_count"));

    private final NamedParameterJdbcTemplate jdbc;

    public TagRepository(NamedParameterJdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    /** 按作品数降序、同分按名称升序；{@code workType} 为 null 时统计全部类型。 */
    public List<TagDtos.TagItem> top(String workType, int limit) {
        StringBuilder sql = new StringBuilder(
                "SELECT tag AS name, COUNT(*) AS work_count FROM work_tag");
        MapSqlParameterSource params = new MapSqlParameterSource().addValue("limit", limit);
        if (workType != null) {
            sql.append(" WHERE work_type = :workType");
            params.addValue("workType", workType);
        }
        sql.append(" GROUP BY tag ORDER BY work_count DESC, tag ASC LIMIT :limit");
        return jdbc.query(sql.toString(), params, MAPPER);
    }
}

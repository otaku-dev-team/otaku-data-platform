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
 * <p>**这里没有「便宜的查询写法」**——别再照着直觉改：{@code GROUP BY tag} 后面跟着
 * 按计数倒序的 {@code ORDER BY}，MySQL 用不上松散索引扫描（loose index scan）。
 * 实测（2026-10-27，222,060 行 {@code work_tag}）EXPLAIN 是
 * {@code Using index; Using temporary; Using filesort}，强制 {@code FORCE INDEX(PRIMARY)} 也一样，
 * 单次 140 ms，成本与行数成正比。真实词表是 **25,069 个标签**（不是几百条），
 * 全量 55.7 万部作品时这条查询约 1.7 s。
 *
 * <p>所以调用方必须经过 {@link TagCache}：缓存的是「前 N 条」整份结果，
 * 由导入结束整体失效。本类只负责把 SQL 写对，不负责让它变快。
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

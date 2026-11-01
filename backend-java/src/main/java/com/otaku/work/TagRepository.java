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

    /**
     * 按作品数降序、同分按名称升序；{@code workType} 为 null 时统计全部类型。
     *
     * <p>成人作品不计数：它们的标签行 {@code is_adult = 1}，被这条条件整行排除，
     * 于是成人词自己的计数直接变 0、自然从词表里消失（不需要再传一份黑名单进来比对），
     * 正常词的计数也不会虚高——避免「词表说 949 部、点进去只有 700 部」。
     *
     * <p>同理不给档案来源的作品计数（口径见 {@code WorkRepository.LIST_SCOPE}）：
     * 词表里出现一个只在 bangumi 档案里有的标签，点进去就是空列表。
     * 代价是必须回表看 {@code work.source}——V25 的注释实测过这条路（词表 JOIN work
     * 约 2.6 s，不 JOIN 190 ms），但词表由 {@code TagCache} 按类型缓存、导入才失效，
     * 一次冷启动换正确性，值。真要抹掉这 2.6 s 就给 work_tag 冗余一列 source。
     */
    public List<TagDtos.TagItem> top(String workType, int limit) {
        StringBuilder sql = new StringBuilder(
                "SELECT t.tag AS name, COUNT(*) AS work_count FROM work_tag t"
                        + " JOIN work w ON w.id = t.work_ref"
                        + " WHERE t.is_adult = 0 AND w.source <> 'bangumi'");
        MapSqlParameterSource params = new MapSqlParameterSource().addValue("limit", limit);
        if (workType != null) {
            sql.append(" AND t.work_type = :workType");
            params.addValue("workType", workType);
        }
        sql.append(" GROUP BY tag ORDER BY work_count DESC, tag ASC LIMIT :limit");
        return jdbc.query(sql.toString(), params, MAPPER);
    }
}

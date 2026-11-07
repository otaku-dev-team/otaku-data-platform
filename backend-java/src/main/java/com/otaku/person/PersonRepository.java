package com.otaku.person;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Repository;

import java.util.List;
import java.util.Optional;

/**
 * 人物页（B2 / #455）的读模型：`people` 一行 + 这个人参与过的作品。
 *
 * <p>数据从 V15 建的三张关系表来（`work_staff` / `work_characters`），**不新增表**：
 * 「谁参与了哪部作品」本来就在那里，缺的只是一个能从人反查过去的入口。
 *
 * <p><b>索引（2026-11-07 已补）</b>：V15 建表时只有 `work_ref` 前缀索引，人物页按
 * `person_id` 反查是两次全表扫。2026-11-06 上线后实测 `GET /api/persons/1` 为
 * **0.46–0.57 s**（同机作品列表 7–13 ms）；把三次扫描压成一次后降到 0.14–0.17 s。
 * V33 落地后迁移号不再被挡，**V36 补了** `idx_work_staff_person` 与
 * `idx_work_characters_person`，反查回到索引量级。
 */
@Repository
public class PersonRepository {

    /**
     * `GROUP_CONCAT` 的分隔符。
     *
     * <p>不用逗号：人名里会出现逗号（「佐藤, 健」这类来源原值）。选 `§` 是因为它
     * 既不会出现在中日文人名里，也能在 SQL 字面量里直接写、不用转义控制字符。
     */
    private static final String SEP = "§";

    private final NamedParameterJdbcTemplate jdbc;

    /**
     * 是否按「首站收录范围」过滤（`work.site_listed = 1`）。
     *
     * <p>与 {@code WorkRepository} 同一个开关、同一个默认值：人物页的作品列表若比作品库
     * 多出来一批「app 里搜不到」的作品，用户点进去就是 404。
     */
    private final boolean siteScopeEnabled;

    public PersonRepository(NamedParameterJdbcTemplate jdbc,
                            @Value("${app.work.site-scope.enabled:true}") boolean siteScopeEnabled) {
        this.jdbc = jdbc;
        this.siteScopeEnabled = siteScopeEnabled;
    }

    /** 人物本体。查不到返回 empty（控制器转 404）。 */
    public Optional<PersonRow> findPerson(String personId) {
        List<PersonRow> rows = jdbc.query(
                "SELECT source_id, name, entity_type FROM people WHERE source_id = :personId"
                        + " ORDER BY id LIMIT 1",
                new MapSqlParameterSource("personId", personId),
                (rs, rowNum) -> new PersonRow(
                        rs.getString("source_id"),
                        rs.getString("name"),
                        rs.getString("entity_type")));
        return rows.stream().findFirst();
    }

    /**
     * 这个人参与过的作品，按评分倒序（无评分排最后），每部一条。
     *
     * <p>三处细节：
     * <ul>
     *   <li>先 UNION 出这个人的全部关系行再 GROUP BY work_ref，而不是 LEFT JOIN 两张表——
     *       后者在「同作品同人既配音又制作」时会做笛卡尔积，`GROUP_CONCAT` 里出现重复；</li>
     *   <li>`GROUP_CONCAT(DISTINCT …)` 自动跳过 NULL：只配音的作品 `roles` 为空串，
     *       由调用方转成空数组；</li>
     *   <li>过滤与作品库一致（成人 / 已下架 / 收录范围），否则人物页会给出一批打不开的卡片。</li>
     * </ul>
     */
    public List<CreditRow> findWorks(String personId) {
        return jdbc.query("""
                        SELECT w.work_id,
                               GROUP_CONCAT(DISTINCT x.role ORDER BY x.role SEPARATOR '§') AS roles,
                               GROUP_CONCAT(DISTINCT x.character_name ORDER BY x.character_name SEPARATOR '§') AS characters
                          FROM (
                                SELECT work_ref, role, NULL AS character_name
                                  FROM work_staff WHERE person_id = :personId
                                UNION ALL
                                SELECT work_ref, NULL AS role, name AS character_name
                                  FROM work_characters WHERE person_id = :personId
                               ) x
                          JOIN work w ON w.id = x.work_ref
                         WHERE w.is_adult = 0 AND w.deleted_at IS NULL
                        """ + (siteScopeEnabled ? "   AND w.site_listed = 1\n" : "")
                        + """
                         GROUP BY w.id, w.work_id
                         ORDER BY w.rating_sort DESC, w.id DESC
                        """,
                new MapSqlParameterSource("personId", personId),
                (rs, rowNum) -> new CreditRow(
                        rs.getString("work_id"),
                        split(rs.getString("roles")),
                        split(rs.getString("characters"))));
    }

    /** 配音作品数（按作品去重）。 */
    public long countCastWorks(String personId) {
        return countWorks("work_characters", personId);
    }

    /** 制作作品数（按作品去重）。 */
    public long countCreditWorks(String personId) {
        return countWorks("work_staff", personId);
    }

    private long countWorks(String table, String personId) {
        // 表名来自本类的两个字面量调用点，不接受外部输入，不存在注入面。
        Long total = jdbc.queryForObject(
                "SELECT COUNT(DISTINCT c.work_ref) FROM " + table + " c"
                        + " JOIN work w ON w.id = c.work_ref"
                        + " WHERE c.person_id = :personId AND w.is_adult = 0 AND w.deleted_at IS NULL"
                        + (siteScopeEnabled ? " AND w.site_listed = 1" : ""),
                new MapSqlParameterSource("personId", personId),
                Long.class);
        return total == null ? 0L : total;
    }

    private static List<String> split(String concatenated) {
        if (concatenated == null || concatenated.isEmpty()) {
            return List.of();
        }
        return List.of(concatenated.split(SEP, -1));
    }

    /** people 表里的一行。 */
    public record PersonRow(String personId, String name, String entityType) {
    }

    /** 一部参与作品：作品 id + 角色 + 职责。 */
    public record CreditRow(String workId, List<String> roles, List<String> characters) {
    }
}

package com.otaku.schedule;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Repository;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Optional;

/**
 * schedule 表的读写。
 *
 * <p>JSON 列存原文（见 {@link ScheduleRecord} 的说明）：写入方负责序列化，
 * 读出时统一过 compact 序列化归一，保证"是否变化"可比较。
 *
 * <p>排序统一 {@code id ASC}：档期没有深页翻页需求（一个季度就几百条，
 * 按星期分组一次取完），稳定顺序只是为了让接口返回可预期。
 */
@Repository
public class ScheduleRepository {

    private static final String COLUMNS = """
            id, schedule_id, source, source_id, season_code,
            title_main, title_cn, title_jp,
            weekday, broadcast_time, broadcast_note, work_type,
            work_tags, image_url, platforms, source_url,
            content_id, work_id, source_updated_at, created_at, updated_at
            """;

    private static final RowMapper<ScheduleRecord> MAPPER = ScheduleRepository::map;

    /**
     * 读库时把 JSON 列归一成紧凑形式。当前只用于 work_tags（字符串数组）。
     *
     * <p>MySQL 会把 JSON 列重新格式化后读出（`["a","b"]` 变 `["a", "b"]`），
     * 若"是否变化"用字符串比较，每次重跑都会判成 changed → 变成 updated，
     * "重跑应全部 unchanged"就挂了。所以读出一律过紧凑序列化，与写入侧
     * （{@code ObjectMapper.writeValueAsString}）严格可比。
     *
     * <p>platforms 不走这里：它是 TEXT 列（MySQL 的 JSON 列会按 key 重排对象，
     * 字符串比较永远不相等，详见 V8 迁移文件头）。
     */
    private static final ObjectMapper JSON = new ObjectMapper();

    private static String canonicalJson(String json) {
        if (json == null || json.isBlank()) {
            return null;
        }
        try {
            return JSON.readTree(json).toString();
        } catch (Exception ex) {
            // 解析不了按未提供处理：这一列是附加信息，不该让整条档期读不出来。
            return null;
        }
    }

    private final NamedParameterJdbcTemplate jdbc;

    public ScheduleRepository(NamedParameterJdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public Optional<ScheduleRecord> findBySourceKey(String source, String sourceId) {
        List<ScheduleRecord> rows = jdbc.query(
                "SELECT " + COLUMNS + " FROM schedule WHERE source = :source AND source_id = :sourceId",
                new MapSqlParameterSource().addValue("source", source).addValue("sourceId", sourceId),
                MAPPER);
        return rows.stream().findFirst();
    }

    public Optional<ScheduleRecord> findByScheduleId(String scheduleId) {
        List<ScheduleRecord> rows = jdbc.query(
                "SELECT " + COLUMNS + " FROM schedule WHERE schedule_id = :scheduleId",
                new MapSqlParameterSource("scheduleId", scheduleId),
                MAPPER);
        return rows.stream().findFirst();
    }

    /**
     * 按星期取条目。{@code weekday} 为 {@code null} 时取"待定"组。
     *
     * <p>用 MySQL 的 NULL 安全相等 {@code <=>} 而不是 {@code =}：后者遇到 NULL 参数
     * 永远不匹配，会把"待定"组查成空列表，而空列表在这里是合法数据，
     * 错了也看不出来。
     *
     * <p>注意这里**必须**用 {@code <=>}（或 {@code IS NULL} 动态拼）而不是动态省略
     * WHERE：参数为 null 在本方法里是有含义的——它就是"查待定组"。
     * 若照资讯那边的做法直接省掉条件，null 会变成"查全部"，星期分组全乱。
     *
     * <p>另：别写成 {@code IS NOT DISTINCT FROM}，那是 PostgreSQL 语法，
     * MySQL 直接报 1064（本机实测踩过）。
     */
    public List<ScheduleRecord> findByWeekday(Integer weekday) {
        String sql = "SELECT " + COLUMNS + " FROM schedule WHERE weekday <=> :weekday"
                + " ORDER BY id ASC";
        return jdbc.query(sql, new MapSqlParameterSource("weekday", weekday), MAPPER);
    }

    /** 按季度取全部条目，接口层自己按星期分组。 */
    public List<ScheduleRecord> findBySeason(String seasonCode) {
        String sql = "SELECT " + COLUMNS + " FROM schedule WHERE season_code = :seasonCode"
                + " ORDER BY weekday ASC, id ASC";
        return jdbc.query(sql, new MapSqlParameterSource("seasonCode", seasonCode), MAPPER);
    }

    /** 库里出现过的全部季度编码，新的在前。给"切换季度"用。 */
    public List<String> findSeasonCodes() {
        return jdbc.queryForList(
                "SELECT DISTINCT season_code FROM schedule WHERE season_code IS NOT NULL"
                        + " ORDER BY season_code DESC",
                new MapSqlParameterSource(),
                String.class);
    }

    /** 当前有条目的最新季度；空表或全部缺 season_code 时返回 null。 */
    public String findLatestSeason() {
        List<String> rows = jdbc.queryForList(
                "SELECT season_code FROM schedule WHERE season_code IS NOT NULL"
                        + " ORDER BY season_code DESC LIMIT 1",
                new MapSqlParameterSource(),
                String.class);
        return rows.isEmpty() ? null : rows.get(0);
    }

    public void insert(ScheduleRecord record) {
        String sql = """
                INSERT INTO schedule (schedule_id, source, source_id, season_code,
                                      title_main, title_cn, title_jp,
                                      weekday, broadcast_time, broadcast_note, work_type,
                                      work_tags, image_url, platforms, source_url,
                                      content_id, work_id, source_updated_at,
                                      created_at, updated_at)
                VALUES (:scheduleId, :source, :sourceId, :seasonCode,
                        :titleMain, :titleCn, :titleJp,
                        :weekday, :broadcastTime, :broadcastNote, :workType,
                        :workTagsJson, :imageUrl, :platformsJson, :sourceUrl,
                        :contentId, :workId, :sourceUpdatedAt,
                        :createdAt, :updatedAt)
                """;
        jdbc.update(sql, params(record)
                .addValue("createdAt", record.createdAt())
                .addValue("updatedAt", record.updatedAt()));
    }

    public void update(ScheduleRecord record) {
        String sql = """
                UPDATE schedule
                   SET season_code       = :seasonCode,
                       title_main        = :titleMain,
                       title_cn          = :titleCn,
                       title_jp          = :titleJp,
                       weekday           = :weekday,
                       broadcast_time    = :broadcastTime,
                       broadcast_note    = :broadcastNote,
                       work_type         = :workType,
                       work_tags         = :workTagsJson,
                       image_url         = :imageUrl,
                       platforms         = :platformsJson,
                       source_url        = :sourceUrl,
                       content_id        = :contentId,
                       work_id           = :workId,
                       source_updated_at = :sourceUpdatedAt,
                       updated_at        = :updatedAt
                 WHERE id = :id
                """;
        jdbc.update(sql, params(record)
                .addValue("id", record.id())
                .addValue("updatedAt", record.updatedAt()));
    }

    private MapSqlParameterSource params(ScheduleRecord record) {
        return new MapSqlParameterSource()
                .addValue("scheduleId", record.scheduleId())
                .addValue("source", record.source())
                .addValue("sourceId", record.sourceId())
                .addValue("seasonCode", record.seasonCode())
                .addValue("titleMain", record.titleMain())
                .addValue("titleCn", record.titleCn())
                .addValue("titleJp", record.titleJp())
                .addValue("weekday", record.weekday())
                .addValue("broadcastTime", record.broadcastTime())
                .addValue("broadcastNote", record.broadcastNote())
                .addValue("workType", record.workType())
                .addValue("workTagsJson", record.workTagsJson())
                .addValue("imageUrl", record.imageUrl())
                .addValue("platformsJson", record.platformsJson())
                .addValue("sourceUrl", record.sourceUrl())
                .addValue("contentId", record.contentId())
                .addValue("workId", record.workId())
                .addValue("sourceUpdatedAt", record.sourceUpdatedAt());
    }

    private static ScheduleRecord map(ResultSet rs, int rowNum) throws SQLException {
        return new ScheduleRecord(
                rs.getLong("id"),
                rs.getString("schedule_id"),
                rs.getString("source"),
                rs.getString("source_id"),
                rs.getString("season_code"),
                rs.getString("title_main"),
                rs.getString("title_cn"),
                rs.getString("title_jp"),
                // getObject：getInt 会把 NULL 读成 0，而 0 在本表不是合法星期
                // （星期是 1..7，待定是 NULL），会凭空造出一个"周日 0 点"。
                rs.getObject("weekday", Integer.class),
                rs.getString("broadcast_time"),
                rs.getString("broadcast_note"),
                rs.getString("work_type"),
                canonicalJson(rs.getString("work_tags")),
                rs.getString("image_url"),
                // platforms 是 TEXT 列（不是 JSON 列，理由见 V8 迁移文件头）：
                // MySQL 不对 TEXT 做任何重排，读出与写入严格相等，不过归一。
                rs.getString("platforms"),
                rs.getString("source_url"),
                rs.getString("content_id"),
                rs.getString("work_id"),
                rs.getObject("source_updated_at", LocalDateTime.class),
                rs.getObject("created_at", LocalDateTime.class),
                rs.getObject("updated_at", LocalDateTime.class));
    }
}

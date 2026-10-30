package com.otaku.appconfig;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;

import java.sql.Timestamp;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * 运行期配置的读写（表 {@code app_config}）。
 *
 * <p>为什么要有它：以前「改一个词 / 调一个开关」= 改 Java 常量 → 打包 → 传 jar → 重建容器。
 * 2026-10-31 一天为成人词表发了两次版，成本就摆在那。现在这类改动走一条 PUT，
 * 客户端下次拉取即生效。
 *
 * <p>缓存形状：整表一次性读进内存（配置条目是个位数到几十条），
 * 用 {@code MAX(updated_at)} 兼作版本号——**写入天然让它变大**，客户端拿它判断要不要刷新缓存。
 * 不额外维护自增版本列，省一个可能回退的状态。
 *
 * <p>单实例假设与 {@code TagCache} / {@code CountCache} 一致：多副本时各进程各一份，
 * 某个实例写入后其它实例要等下一次 {@link #reload()}（当前部署是单实例）。
 */
@Service
public class AppConfigService implements ConfigSource {

    private static final Logger log = LoggerFactory.getLogger(AppConfigService.class);

    private static final ObjectMapper MAPPER = new ObjectMapper();

    private final JdbcTemplate jdbc;

    private volatile Snapshot snapshot;

    public AppConfigService(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    /**
     * 一份配置快照。
     *
     * @param version 版本（毫秒时间戳）；表为空时是 0
     * @param values  键 → 值；**只含库里存过的键**，缺键由各消费方用自己的默认值兜底
     */
    public record Snapshot(long version, Map<String, JsonNode> values) {

        public JsonNode get(String key) {
            return values.get(key);
        }
    }

    /** 读当前快照（懒加载 + 常驻）。 */
    @Override
    public Snapshot current() {
        Snapshot local = snapshot;
        if (local == null) {
            synchronized (this) {
                local = snapshot;
                if (local == null) {
                    local = load();
                    snapshot = local;
                }
            }
        }
        return local;
    }

    /** 某个键的值；缺键返回 null。 */
    public JsonNode value(String key) {
        return current().get(key);
    }

    /**
     * 写一个键并让快照立即失效。
     *
     * <p>用 upsert 而不是「先查再插」：并发两次写入时前者是原子的，
     * 后者会在唯一键上撞车（这个接口虽然只有平台能调，但没有理由让它怕并发）。
     */
    public Snapshot put(String key, JsonNode value, String note) {
        jdbc.update("""
                        INSERT INTO app_config (config_key, config_value, note, updated_at)
                        VALUES (?, CAST(? AS JSON), ?, NOW(3))
                        ON DUPLICATE KEY UPDATE config_value = VALUES(config_value),
                                                note = IFNULL(VALUES(note), note),
                                                updated_at = NOW(3)
                        """,
                key, value.toString(), note);
        Snapshot fresh = load();
        snapshot = fresh;
        log.info("配置已更新 key={} version={}", key, fresh.version());
        return fresh;
    }

    /** 丢掉缓存，下次读取时重查（多实例部署时给其它节点用）。 */
    public Snapshot reload() {
        Snapshot fresh = load();
        snapshot = fresh;
        return fresh;
    }

    private Snapshot load() {
        Map<String, JsonNode> values = new LinkedHashMap<>();
        long[] version = {0L};
        jdbc.query("SELECT config_key, config_value, updated_at FROM app_config ORDER BY config_key",
                rs -> {
                    String key = rs.getString("config_key");
                    Timestamp updatedAt = rs.getTimestamp("updated_at");
                    try {
                        values.put(key, MAPPER.readTree(rs.getString("config_value")));
                    } catch (Exception ex) {
                        // 坏值不该让整个配置接口 500：跳过并留日志，消费方按"缺键"处理
                        log.warn("配置值不是合法 JSON，已跳过 key={}：{}", key, ex.getMessage());
                        return;
                    }
                    if (updatedAt != null) {
                        version[0] = Math.max(version[0], updatedAt.getTime());
                    }
                });
        return new Snapshot(version[0], Map.copyOf(values));
    }
}

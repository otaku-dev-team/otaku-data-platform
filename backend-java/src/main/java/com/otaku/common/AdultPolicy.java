package com.otaku.common;

import com.fasterxml.jackson.databind.JsonNode;
import com.otaku.appconfig.AppConfigService;
import com.otaku.appconfig.ConfigSource;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Set;

/**
 * 成人内容判定的**运行期视图**：读库里的配置（`app_config`），缺键时回落到代码默认值。
 *
 * <p>为什么要多这一层：判定有四个消费方（作品写入打标、三个出口的 tags 剔除、档期查询），
 * 而词表本身要能热改——如果每个地方直接读常量，改词就得发版；如果每个地方各自读库，
 * 又会各算一遍、还可能在不同时刻看到不同快照。这里统一成一个带版本的派生对象：
 * 配置版本变了才重建一次派生数据（Set / 小写匹配表 / JSON 文本）。
 *
 * <p>三个可配置项（键名即 {@code app_config.config_key}）：
 * <ul>
 *   <li>{@code adult.hidden}：总开关，false = 整块遮挡下线（重建标记时会把 is_adult 全清零）；</li>
 *   <li>{@code adult.tags}：成人标签数组，缺键用 {@link AdultTags#NAMES}；</li>
 *   <li>{@code adult.title_markers}：标题兜底标记，缺键用 {@link AdultTags#TITLE_MARKERS}。</li>
 * </ul>
 *
 * <p>改配置后必须重建 {@code work.is_adult}（见 {@code AdultFlagRebuilder}），
 * 否则词表变了而存量标记没跟上——「改了词表但旧作品还露着」这种半生效状态最难查。
 */
@Component
public class AdultPolicy {

    public static final String KEY_HIDDEN = "adult.hidden";
    public static final String KEY_TAGS = "adult.tags";
    public static final String KEY_TITLE_MARKERS = "adult.title_markers";

    private final ConfigSource config;

    private volatile Derived derived;

    public AdultPolicy(ConfigSource config) {
        this.config = config;
    }

    public boolean hidden() {
        return current().hidden;
    }

    /** 生效中的成人标签（已按配置覆盖）。 */
    public List<String> tagNames() {
        return current().tags;
    }

    /** 供 SQL 的 {@code JSON_OVERLAPS(tags, CAST(:adultTags AS JSON))} 用。 */
    public String tagsJson() {
        return current().tagsJson;
    }

    public List<String> titleMarkers() {
        return current().titleMarkers;
    }

    public boolean isAdultTag(String tag) {
        Derived snapshot = current();
        return tag != null && snapshot.hidden && snapshot.tagSet.contains(tag);
    }

    /**
     * 剔除成人标签，保留 {@code null} 与 {@code []} 的三态语义（见 {@code Work.tags}）。
     * 总开关关掉时原样返回——遮挡下线后不该再动用户的标签。
     */
    public List<String> strip(List<String> tags) {
        Derived snapshot = current();
        if (!snapshot.hidden) {
            return tags;
        }
        return AdultTags.strip(tags, snapshot.tagSet);
    }

    /** 标题是否带成人标记；总开关关掉时一律 false。 */
    public boolean titleLooksAdult(String title) {
        Derived snapshot = current();
        if (!snapshot.hidden) {
            return false;
        }
        return AdultTags.titleLooksAdult(title, snapshot.titleMarkersLower);
    }

    private Derived current() {
        AppConfigService.Snapshot snapshot = config.current();
        Derived local = derived;
        if (local != null && local.version == snapshot.version()) {
            return local;
        }
        Derived fresh = derive(snapshot);
        derived = fresh;
        return fresh;
    }

    private static Derived derive(AppConfigService.Snapshot snapshot) {
        boolean hidden = asBoolean(snapshot.get(KEY_HIDDEN), true);
        List<String> tags = asStringList(snapshot.get(KEY_TAGS), AdultTags.NAMES);
        List<String> markers = asStringList(snapshot.get(KEY_TITLE_MARKERS), AdultTags.TITLE_MARKERS);
        return new Derived(snapshot.version(), hidden, tags, markers);
    }

    private static boolean asBoolean(JsonNode node, boolean fallback) {
        if (node == null || node.isNull()) {
            return fallback;
        }
        if (node.isBoolean()) {
            return node.booleanValue();
        }
        // 手写配置时容易写成字符串 "false" —— 直接 asBoolean 会得到 true，必须显式判
        return "true".equalsIgnoreCase(node.asText()) || "1".equals(node.asText());
    }

    private static List<String> asStringList(JsonNode node, List<String> fallback) {
        if (node == null || !node.isArray() || node.isEmpty()) {
            return fallback;
        }
        List<String> values = new ArrayList<>(node.size());
        node.forEach(item -> {
            String text = item.asText();
            if (text != null && !text.isBlank()) {
                values.add(text);
            }
        });
        return values.isEmpty() ? fallback : List.copyOf(values);
    }

    /** 派生数据：只在配置版本变化时重建一次，避免每个作品都重算 Set / 小写表 / JSON。 */
    private static final class Derived {

        private final long version;
        private final boolean hidden;
        private final List<String> tags;
        private final Set<String> tagSet;
        private final List<String> titleMarkers;
        private final List<String> titleMarkersLower;
        private final String tagsJson;

        private Derived(long version, boolean hidden, List<String> tags, List<String> titleMarkers) {
            this.version = version;
            this.hidden = hidden;
            this.tags = tags;
            this.tagSet = Set.copyOf(tags);
            this.titleMarkers = titleMarkers;
            this.titleMarkersLower = titleMarkers.stream()
                    .map(marker -> marker.toLowerCase(Locale.ROOT))
                    .toList();
            this.tagsJson = AdultTags.toJson(tags);
        }
    }
}

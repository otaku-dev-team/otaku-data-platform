package com.otaku.common;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.appconfig.AppConfigService;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 运行期成人策略：缺键回落默认、覆盖生效、总开关能整块下线。
 *
 * <p>这层最容易出的错是「改了配置但某个出口没跟着变」——所以每个断言都从**三个消费面**
 * （判定单标签 / 剔除列表 / 标题兜底）各问一次，而不是只测一个 getter。
 */
class AdultPolicyTest {

    private static final ObjectMapper MAPPER = new ObjectMapper();

    private static AdultPolicy policy(String... keyValues) {
        Map<String, JsonNode> values = new HashMap<>();
        for (int i = 0; i < keyValues.length; i += 2) {
            try {
                values.put(keyValues[i], MAPPER.readTree(keyValues[i + 1]));
            } catch (Exception ex) {
                throw new IllegalStateException(ex);
            }
        }
        return new AdultPolicy(() -> new AppConfigService.Snapshot(values.isEmpty() ? 0 : 1234L, Map.copyOf(values)));
    }

    @Test
    @DisplayName("没配置时用代码默认值：60 个成人词 + 标题标记都生效")
    void fallsBackToDefaults() {
        AdultPolicy policy = policy();

        assertThat(policy.hidden()).isTrue();
        assertThat(policy.tagNames()).containsExactlyElementsOf(AdultTags.NAMES);
        assertThat(policy.isAdultTag("R18")).isTrue();
        assertThat(policy.strip(List.of("R18", "科幻"))).containsExactly("科幻");
        assertThat(policy.titleLooksAdult("R18! (1)")).isTrue();
        assertThat(policy.titleLooksAdult("街角魔族")).isFalse();
    }

    @Test
    @DisplayName("配置覆盖词表：老词立刻失效、新词立刻生效（三个消费面要一起变）")
    void overrideChangesAllThreeSurfaces() {
        AdultPolicy policy = policy(
                AdultPolicy.KEY_TAGS, "[\"自定义成人词\"]",
                AdultPolicy.KEY_TITLE_MARKERS, "[\"TESTMARK\"]");

        assertThat(policy.isAdultTag("R18")).as("默认词已被覆盖掉").isFalse();
        assertThat(policy.isAdultTag("自定义成人词")).isTrue();
        assertThat(policy.strip(List.of("R18", "自定义成人词", "科幻"))).containsExactly("R18", "科幻");
        assertThat(policy.titleLooksAdult("R18!")).as("标题标记也换掉了").isFalse();
        assertThat(policy.titleLooksAdult("带 testmark 的标题")).as("小写也要命中").isTrue();
        assertThat(policy.tagsJson()).isEqualTo("[\"自定义成人词\"]");
    }

    @Test
    @DisplayName("总开关关掉：判定、剔除、标题兜底全部失效（等于整块下线）")
    void hiddenSwitchTurnsEverythingOff() {
        AdultPolicy policy = policy(AdultPolicy.KEY_HIDDEN, "false");

        assertThat(policy.hidden()).isFalse();
        List<String> tags = List.of("R18", "科幻");
        assertThat(policy.strip(tags)).as("原样返回，连拷贝都不做").isSameAs(tags);
        assertThat(policy.titleLooksAdult("R18!")).isFalse();
        assertThat(policy.isAdultTag("R18")).isFalse();
    }

    @Test
    @DisplayName("手写的 \"false\" 字符串要当真值处理，别被 asBoolean 当成 true")
    void stringBooleanIsParsed() {
        assertThat(policy(AdultPolicy.KEY_HIDDEN, "\"false\"").hidden()).isFalse();
        assertThat(policy(AdultPolicy.KEY_HIDDEN, "\"true\"").hidden()).isTrue();
        assertThat(policy(AdultPolicy.KEY_HIDDEN, "0").hidden()).isFalse();
    }

    @Test
    @DisplayName("空数组不当作「没有成人词」：退回默认，避免手滑清空后整站放开")
    void emptyArrayFallsBackToDefaults() {
        AdultPolicy policy = policy(AdultPolicy.KEY_TAGS, "[]");

        assertThat(policy.tagNames()).containsExactlyElementsOf(AdultTags.NAMES);
        assertThat(policy.isAdultTag("R18")).isTrue();
    }
}

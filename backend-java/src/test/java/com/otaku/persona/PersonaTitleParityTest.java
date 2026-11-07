package com.otaku.persona;

import static org.assertj.core.api.Assertions.assertThat;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.InputStream;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;

/**
 * 称号判定与网站 {@code app/persona.py} 的逐条对照。
 *
 * <p>{@code persona-title-cases.json} 是用**网站原函数**跑出来的黄金集（140 条随机画像，
 * 覆盖 45 个不同称号），不经人手计算。这里只做一件事：同一份输入两边结果必须一模一样。
 * 网站侧改了文案或阈值、这边没跟上时，这个测试会先红。
 *
 * <p>样本里的 {@code drop} 有非零值，是为了验证抛弃相关规则的移植；线上目前恒为 0
 * （otaku 没有「抛弃」这个收藏状态），所以「三集弃之神 / 开幕雷击」暂时命中不了，
 * 等 #496/#506 能把抛弃标注落库后自动生效。
 */
class PersonaTitleParityTest {

    private static final ObjectMapper MAPPER = new ObjectMapper();

    private static List<Map<String, Object>> loadCases() throws Exception {
        try (InputStream in = PersonaTitleParityTest.class
                .getResourceAsStream("/persona-title-cases.json")) {
            assertThat(in).as("persona-title-cases.json 应在 test resources 里").isNotNull();
            return MAPPER.readValue(in, new TypeReference<>() {});
        }
    }

    private static PersonaTitle.Input toInput(Map<String, Object> raw) {
        @SuppressWarnings("unchecked")
        Map<String, Object> dims = (Map<String, Object>) raw.get("dimensions");
        Map<String, Double> dimensions = new LinkedHashMap<>();
        dims.forEach((k, v) -> dimensions.put(k, ((Number) v).doubleValue()));

        @SuppressWarnings("unchecked")
        Map<String, Object> genres = (Map<String, Object>) raw.get("genreCounts");
        Map<String, Integer> genreCounts = new LinkedHashMap<>();
        genres.forEach((k, v) -> genreCounts.put(k, ((Number) v).intValue()));

        return new PersonaTitle.Input(
                dimensions,
                ((Number) raw.get("total")).intValue(),
                ((Number) raw.get("want")).intValue(),
                ((Number) raw.get("seen")).intValue(),
                ((Number) raw.get("drop")).intValue(),
                (String) raw.get("cluster"),
                (String) raw.get("identity"),
                genreCounts,
                ((Number) raw.get("earlyShare")).doubleValue(),
                (String) raw.get("rarityTier"));
    }

    @Test
    void matchesSiteOnEveryGoldenCase() throws Exception {
        List<Map<String, Object>> cases = loadCases();
        assertThat(cases).hasSizeGreaterThan(100);

        int failed = 0;
        StringBuilder report = new StringBuilder();
        for (int i = 0; i < cases.size(); i++) {
            Map<String, Object> c = cases.get(i);
            @SuppressWarnings("unchecked")
            Map<String, Object> rawInput = (Map<String, Object>) c.get("input");
            PersonaTitle.Input input = toInput(rawInput);
            String seed = (String) c.get("seed");

            PersonaTitle.Title actual = PersonaTitle.assign(input, seed);
            String expectedCode = (String) c.get("expectedCode");
            String expectedTitle = (String) c.get("expectedTitle");
            String expectedNote = (String) c.get("expectedNote");

            boolean ok = expectedCode.equals(actual.code())
                    && expectedTitle.equals(actual.title())
                    && expectedNote.equals(actual.note());
            if (!ok) {
                failed++;
                report.append("\n#").append(i)
                        .append(" cluster=").append(rawInput.get("cluster"))
                        .append(" identity=").append(rawInput.get("identity"))
                        .append("\n  want=").append(actual.code()).append('/').append(actual.title())
                        .append(" vs ").append(expectedCode).append('/').append(expectedTitle)
                        .append("\n  note=").append(actual.note())
                        .append("\n  want=").append(expectedNote);
            }
        }
        assertThat(failed).as("与网站不一致的样本数%s", report).isZero();
    }

    @Test
    void traitsMatchSite() throws Exception {
        for (Map<String, Object> c : loadCases()) {
            @SuppressWarnings("unchecked")
            Map<String, Object> rawInput = (Map<String, Object>) c.get("input");
            PersonaTitle.Input input = toInput(rawInput);
            @SuppressWarnings("unchecked")
            List<String> expected = (List<String>) c.get("expectedTraits");
            assertThat(PersonaTitle.traits(input)).isEqualTo(expected);
        }
    }

    @Test
    void everyQuipCodeHasCopy() {
        // 主表 / 六层引用到的代号都必须有文案，否则页面会出现「只有称号、没有话」
        assertThat(PersonaCopyData.QUIPS).hasSizeGreaterThan(90);
        PersonaCopyData.TITLE_MAIN.values().forEach(row -> row.values().forEach(quip -> {
            assertThat(PersonaCopyData.QUIPS).containsKey(quip.code());
            assertThat(quip.notes()).isNotEmpty();
            assertThat(quip.title()).isNotBlank();
        }));
        PersonaCopyData.IDENTITY_CODE.values()
                .forEach(code -> assertThat(PersonaCopyData.QUIPS).containsKey(code));
    }

    @Test
    void rarityFallsBackToUnratedInsteadOfRarest() {
        PersonaTitle.Rarity rated = PersonaTitle.rarity("PIXIU");
        assertThat(rated.tier()).isEqualTo("SSR");
        assertThat(rated.share()).isEqualTo(0.30);

        // 校准样本里没出现过的称号不等于「最稀有」，是「还没测出来」
        PersonaTitle.Rarity unrated = PersonaTitle.rarity("NOT-IN-SAMPLE");
        assertThat(unrated.tier()).isEqualTo("?");
        assertThat(unrated.label()).isEqualTo("未标定");
        assertThat(unrated.share()).isNull();

        // 真实占比优先于校准先验
        assertThat(PersonaTitle.rarity("FLOAT", 0.4).tier()).isEqualTo("SSR");
    }

    @Test
    void clusterFallsBackToOmnivoreWhenNothingDominates() {
        // 八个簇平均分摊 → 最大簇远不到 18%，判杂食
        assertThat(PersonaTitle.cluster(Map.of(
                "治愈", 1, "热血", 1, "悬疑", 1, "科幻", 1,
                "恋爱", 1, "奇幻", 1, "搞笑", 1, "音乐", 1))).isEqualTo("杂食");
        // 单一簇压倒性占多数 → 就是它
        assertThat(PersonaTitle.cluster(Map.of("科幻", 80, "恋爱", 5))).isEqualTo("科幻");
        assertThat(PersonaTitle.cluster(Map.of())).isEqualTo("杂食");
    }

    @Test
    void identityIsMajorityOrOmnivore() {
        assertThat(PersonaTitle.identity(Map.of(
                "anime", 62.0, "comic", 20.0, "game", 10.0, "novel", 8.0))).isEqualTo("番剧党");
        // 谁都没过半 -> 杂食党
        assertThat(PersonaTitle.identity(Map.of(
                "anime", 40.0, "comic", 35.0, "game", 25.0))).isEqualTo("杂食党");
        // 正好一半也算主身份（网站判据是「不足一半」才判杂食）
        assertThat(PersonaTitle.identity(Map.of("novel", 50.0))).isEqualTo("轻小说党");
        assertThat(PersonaTitle.identity(Map.of("game", 88.0))).isEqualTo("游戏宅");
        assertThat(PersonaTitle.identity(Map.of())).isEqualTo("杂食党");
    }

    @Test
    void blurbLookupCoversEveryPersonaTag() {
        PersonaTitle.Input input = new PersonaTitle.Input(
                Map.of("mainstream", 40.0, "tag_focus", 70.0, "exploration", 70.0,
                        "quality", 80.0, "fresh", 55.0),
                120, 80, 40, 0, "科幻", "番剧党", Map.of("科幻", 40), 10, null);

        List<String> tags = PersonaTitle.personaTags(input);
        assertThat(tags.get(0)).isEqualTo("科幻系");
        assertThat(tags.get(1)).isEqualTo("番剧党");

        Map<String, String> blurbs = PersonaTitle.traitBlurbs(input);
        blurbs.forEach((tag, text) -> assertThat(text).as("标签 %s 缺说明", tag).isNotBlank());
    }
}

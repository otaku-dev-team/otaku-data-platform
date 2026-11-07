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
 * 在**真实形态**的画像上验证称号判定，并守住「称号不会塌缩」这条线。
 *
 * <p>{@code persona-calibration-cases.json} 取自网站用来校准阈值的模拟画像——按人群
 * 原型从站内库抽样造的，维度分布与真实用户接近。随机样本验的是「口径有没有抄错」，
 * 这组验的是「真数据上跑出来还是同一批人」。
 *
 * <p>原集 336 条里有 35 条被剔掉：它们的期望称号依赖当时收藏行为数据（想看 / 看过 /
 * 抛弃的条数），而存档只留了维度和标签，那几项复原不了。依赖行为数据的 6 个称号
 * （赛博貔貅 / 三集弃之神 / 开幕雷击 / 有始有终的异类 / 自宅警备员 / 老贼）与带
 * 「仓鼠」特征的画像因此不进这组；它们由 {@link PersonaTitleParityTest} 覆盖
 * ——那组的输入是完整构造的。剩下 301 条、29 个称号，全部逐条比对。
 *
 * <p>分布断言不是目标值，是**回归闸门**：网站那边调整过好几轮阈值，其中一次让
 * 单个称号吃掉 13.7% 的人，另一次让 27.4% 的人全掉进同一个兜底。口径再动时，
 * 这里会先红。
 */
class PersonaTitleCalibrationTest {

    private static final ObjectMapper MAPPER = new ObjectMapper();

    /** 单个称号占比上限：超过就是塌缩（网站实测基线最大 9.23%）。 */
    private static final double MAX_SHARE_PERCENT = 15.0;

    /** 至少要分出这么多不同称号，否则等于没在区分人。 */
    private static final int MIN_DISTINCT_TITLES = 25;

    private static List<Map<String, Object>> loadCases() throws Exception {
        try (InputStream in = PersonaTitleCalibrationTest.class
                .getResourceAsStream("/persona-calibration-cases.json")) {
            assertThat(in).as("persona-calibration-cases.json 应在 test resources 里").isNotNull();
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
    void reproducesEveryCalibrationProfile() throws Exception {
        List<Map<String, Object>> cases = loadCases();
        assertThat(cases).hasSize(301);

        int failed = 0;
        StringBuilder report = new StringBuilder();
        for (int i = 0; i < cases.size(); i++) {
            Map<String, Object> c = cases.get(i);
            @SuppressWarnings("unchecked")
            Map<String, Object> rawInput = (Map<String, Object>) c.get("input");
            PersonaTitle.Title actual = PersonaTitle.assign(toInput(rawInput));

            String expectedCode = (String) c.get("expectedCode");
            if (!expectedCode.equals(actual.code())) {
                failed++;
                report.append("\n#").append(i)
                        .append(" cluster=").append(rawInput.get("cluster"))
                        .append(" 得到 ").append(actual.code()).append('/').append(actual.title())
                        .append(" 期望 ").append(expectedCode).append('/').append(c.get("expectedTitle"));
            }
            @SuppressWarnings("unchecked")
            List<String> expectedTraits = (List<String>) c.get("expectedTraits");
            assertThat(PersonaTitle.traits(toInput(rawInput)))
                    .as("第 %d 条的标签", i).isEqualTo(expectedTraits);
        }
        assertThat(failed).as("与校准样本不一致的条数%s", report).isZero();
    }

    @Test
    void titlesDoNotCollapse() throws Exception {
        Map<String, Integer> counts = new LinkedHashMap<>();
        int total = 0;
        for (Map<String, Object> c : loadCases()) {
            @SuppressWarnings("unchecked")
            Map<String, Object> rawInput = (Map<String, Object>) c.get("input");
            String code = PersonaTitle.assign(toInput(rawInput)).code();
            counts.merge(code, 1, Integer::sum);
            total++;
        }

        assertThat(counts.size())
                .as("分出的不同称号数，分布=%s", counts)
                .isGreaterThanOrEqualTo(MIN_DISTINCT_TITLES);

        Map.Entry<String, Integer> top = counts.entrySet().stream()
                .max(Map.Entry.comparingByValue()).orElseThrow();
        double share = top.getValue() * 100.0 / total;
        assertThat(share)
                .as("最集中的称号 %s 占了 %.2f%%，超过 %.1f%% 说明判据塌缩",
                        top.getKey(), share, MAX_SHARE_PERCENT)
                .isLessThan(MAX_SHARE_PERCENT);
    }
}

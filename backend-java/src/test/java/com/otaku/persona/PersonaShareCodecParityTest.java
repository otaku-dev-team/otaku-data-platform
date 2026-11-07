package com.otaku.persona;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.within;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.InputStream;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import org.junit.jupiter.api.Test;

/**
 * 分享口径与网站 {@code app/persona.py} 的逐条对照。
 *
 * <p>{@code persona-share-cases.json} 由网站原函数生成：编码按字节比对 token，
 * 解码（含 8 组畸形输入）比对还原结果，引流文案与占比文案按 seed/数值逐个比对。
 * 两边任何一处口径漂移，这个测试先红。
 */
class PersonaShareCodecParityTest {

    private static final ObjectMapper MAPPER = new ObjectMapper();

    private static List<Map<String, Object>> loadCases() throws Exception {
        try (InputStream in = PersonaShareCodecParityTest.class
                .getResourceAsStream("/persona-share-cases.json")) {
            assertThat(in).as("persona-share-cases.json 应在 test resources 里").isNotNull();
            return MAPPER.readValue(in, new TypeReference<>() {});
        }
    }

    private static Map<String, Double> toDims(Object raw) {
        Map<String, Double> dims = new LinkedHashMap<>();
        if (raw instanceof Map<?, ?> map) {
            map.forEach((k, v) -> dims.put(String.valueOf(k), ((Number) v).doubleValue()));
        }
        return dims;
    }

    @Test
    void encodeProducesSameTokenAsSite() throws Exception {
        int checked = 0;
        for (Map<String, Object> c : loadCases()) {
            if (!"encode".equals(c.get("kind"))) {
                continue;
            }
            @SuppressWarnings("unchecked")
            List<String> tags = (List<String>) c.get("personaTags");
            PersonaShareCodec.RarityBadge rarity = null;
            if (c.get("rarity") instanceof Map<?, ?> r) {
                Object share = r.get("share");
                rarity = new PersonaShareCodec.RarityBadge(
                        (String) r.get("tier"),
                        share == null ? null : ((Number) share).doubleValue(),
                        ((Number) r.get("ratedTotal")).intValue());
            }
            String token = PersonaShareCodec.encode(
                    tags,
                    toDims(c.get("dimensions")),
                    rarity,
                    (String) c.get("heroTitle"),
                    (String) c.get("heroCode"),
                    (String) c.get("quip"),
                    ((Number) c.get("total")).intValue());
            assertThat(token).as("encode %s", c.get("heroTitle")).isEqualTo(c.get("expectedToken"));
            checked++;
        }
        assertThat(checked).isGreaterThanOrEqualTo(5);
    }

    @Test
    void decodeRoundTripsAndRejectsMalformedInput() throws Exception {
        for (Map<String, Object> c : loadCases()) {
            if (!"decode".equals(c.get("kind"))) {
                continue;
            }
            String token = (String) c.get("token");
            Optional<PersonaShareCodec.CardPayload> actual = PersonaShareCodec.decode(token);
            Object expected = c.get("expected");

            if (expected == null) {
                assertThat(actual).as("畸形输入 %s 应被拒", token).isEmpty();
                continue;
            }
            assertThat(actual).as("应能解码 %s", token).isPresent();
            @SuppressWarnings("unchecked")
            Map<String, Object> e = (Map<String, Object>) expected;
            PersonaShareCodec.CardPayload payload = actual.get();

            assertThat(payload.tags()).isEqualTo(e.get("tags"));
            assertThat(payload.total()).isEqualTo(((Number) e.get("total")).intValue());
            assertThat(payload.heroTitle()).isEqualTo(e.get("hero_title"));
            assertThat(payload.heroCode()).isEqualTo(e.get("hero_code"));
            assertThat(payload.quip()).isEqualTo(e.get("quip"));

            @SuppressWarnings("unchecked")
            List<Number> expectedDims = (List<Number>) e.get("dims");
            assertThat(payload.dims()).hasSameSizeAs(expectedDims);
            for (int i = 0; i < expectedDims.size(); i++) {
                assertThat(payload.dims().get(i).doubleValue())
                        .isCloseTo(expectedDims.get(i).doubleValue(), within(1e-9));
            }

            Object rawRarity = e.get("rarity");
            if (rawRarity == null) {
                assertThat(payload.rarity()).isNull();
            } else {
                List<?> r = (List<?>) rawRarity;
                assertThat(payload.rarity()).isNotNull();
                assertThat(payload.rarity().tier()).isEqualTo(String.valueOf(r.get(0)));
                if (r.get(1) == null) {
                    assertThat(payload.rarity().share()).isNull();
                } else {
                    assertThat(payload.rarity().share())
                            .isCloseTo(((Number) r.get(1)).doubleValue(), within(1e-9));
                }
            }
        }
    }

    @Test
    void shareLineMatchesSiteForEverySeed() throws Exception {
        for (Map<String, Object> c : loadCases()) {
            if (!"shareLine".equals(c.get("kind"))) {
                continue;
            }
            String actual = PersonaShareCodec.shareLine(
                    (String) c.get("heroTitle"),
                    (String) c.get("heroNote"),
                    ((Number) c.get("total")).intValue(),
                    (String) c.get("seed"));
            assertThat(actual).isEqualTo(c.get("expected"));
        }
    }

    @Test
    void shareTextKeepsOneDecimalBelowTenPercent() throws Exception {
        for (Map<String, Object> c : loadCases()) {
            if (!"shareText".equals(c.get("kind"))) {
                continue;
            }
            Object raw = c.get("share");
            Double share = raw == null ? null : ((Number) raw).doubleValue();
            assertThat(PersonaShareCodec.shareText(share)).isEqualTo(c.get("expected"));
        }
    }

    @Test
    void rarityCaptionDoesNotInventPercentageForUnrated() {
        assertThat(PersonaShareCodec.rarityCaption("SR", 6.4)).isEqualTo("刹帝利 · 仅 6.4% 同好");
        assertThat(PersonaShareCodec.rarityCaption("N", 42.0)).isEqualTo("路人 · 大众路线");
        // 未标定 ≠ 最稀有：不编百分比
        assertThat(PersonaShareCodec.rarityCaption("?", null)).isEqualTo("未标定 · 校准样本未收录");
        assertThat(PersonaShareCodec.rarityCaption("SSR", 0.3)).isEqualTo("婆罗门 · 仅 0.3% 同好");
        assertThat(PersonaShareCodec.tierColor("SSR")).isEqualTo("#E0A800");
        assertThat(PersonaShareCodec.tierColor("UNKNOWN")).isEqualTo("#7b8896");
    }
}

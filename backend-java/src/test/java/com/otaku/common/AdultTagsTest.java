package com.otaku.common;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.Arrays;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 词表本身的判定规则。
 *
 * <p>这些用例守的是**误杀**而不是漏杀：名单里多写一个词，抹掉的是几千部正常作品的标签，
 * 而且没有任何报错——只能靠用例把「哪些词明确不能进名单」钉住。
 */
class AdultTagsTest {

    @Test
    @DisplayName("明确成人词命中，大小写按原文，不做归一")
    void matchesExplicitAdultWords() {
        assertThat(AdultTags.isAdult("R18")).isTrue();
        assertThat(AdultTags.isAdult("成年コミック")).isTrue();
        assertThat(AdultTags.isAdult("里番")).isTrue();
        assertThat(AdultTags.isAdult("拔作")).isTrue();
        assertThat(AdultTags.isAdult("無修正")).isTrue();

        assertThat(AdultTags.isAdult("r18")).as("库里标签是原文入库，小写 r18 不是同一个值").isFalse();
        assertThat(AdultTags.isAdult(null)).isFalse();
        assertThat(AdultTags.isAdult("")).isFalse();
    }

    @Test
    @DisplayName("题材词与反向标记不能被当成成人词")
    void doesNotMatchGenreOrNegation() {
        // 这几类都在真实词表里出现过，且大量挂在正常作品上：
        // 巨乳 949 部里只有 35% 带 R18；纯爱 1,446 部；非R18 是明确的反向标记。
        for (String safe : List.of("巨乳", "纯爱", "NTR", "调教", "触手", "BL", "BL-Game",
                "蔷薇向", "姐系", "非R18", "成人童话", "科幻", "日常")) {
            assertThat(AdultTags.isAdult(safe)).as(safe).isFalse();
        }
    }

    @Test
    @DisplayName("标题兜底只认明确的成人标记，会出现在正常标题里的词一个都不收")
    void titleMarkers() {
        assertThat(AdultTags.titleLooksAdult("R18!")).isTrue();
        assertThat(AdultTags.titleLooksAdult("r18 (1)")).isTrue();
        assertThat(AdultTags.titleLooksAdult("少年少女18禁")).isTrue();
        assertThat(AdultTags.titleLooksAdult("My Hentai Fantasy")).isTrue();
        assertThat(AdultTags.titleLooksAdult("無修正学級カラレヤ")).isTrue();
        assertThat(AdultTags.titleLooksAdult(null)).isFalse();
        assertThat(AdultTags.titleLooksAdult("")).isFalse();

        // 这三个都在真实数据里出现过，且都是正常作品——收 `エロ` / `成人` 就会误杀
        assertThat(AdultTags.titleLooksAdult("新吼えろペン (1)")).as("吼えろ 里含 エロ").isFalse();
        assertThat(AdultTags.titleLooksAdult("マルドゥック・ヴェロシティ 1")).as("ヴェロシティ").isFalse();
        assertThat(AdultTags.titleLooksAdult("爱的成人式")).as("成人 不等于成人向").isFalse();
        assertThat(AdultTags.titleLooksAdult("街角魔族 2丁目")).isFalse();
    }

    @Test
    @DisplayName("strip 保留 null / [] 的三态语义，不把 null 归一成空列表")
    void stripKeepsNullAndEmptySemantics() {
        assertThat(AdultTags.strip(null)).isNull();
        assertThat(AdultTags.strip(List.of())).isEmpty();

        assertThat(AdultTags.strip(List.of("R18"))).as("只剩成人词 → 空数组").isEmpty();
        assertThat(AdultTags.strip(List.of("R18", "里番", "本子"))).isEmpty();
        assertThat(AdultTags.strip(Arrays.asList("科幻", null, "R18", "日常")))
                .as("null 元素照原样保留（改动前就是这么透传的），只剔除命中的词")
                .containsExactly("科幻", null, "日常");
    }

    @Test
    @DisplayName("没有命中时原样返回同一个列表实例：每个请求都会走这条路，不做无谓拷贝")
    void stripReturnsSameInstanceWhenNothingHidden() {
        List<String> tags = List.of("科幻", "日常");

        assertThat(AdultTags.strip(tags)).isSameAs(tags);
    }

    @Test
    @DisplayName("名单的 JSON 形式 == 名单本身（SQL 参数靠它，序列化错了会静默匹配不到）")
    void jsonMirrorsNames() throws Exception {
        List<String> parsed = new com.fasterxml.jackson.databind.ObjectMapper()
                .readValue(AdultTags.JSON, new com.fasterxml.jackson.core.type.TypeReference<List<String>>() {
                });

        assertThat(parsed).containsExactlyElementsOf(AdultTags.NAMES);
        assertThat(AdultTags.JSON).doesNotContain(" ");
    }
}

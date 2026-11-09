package com.otaku.work;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 搜索词理解（#560）：类型词 / 年份 / 季数。
 *
 * <p>这一层是纯函数，所以每条规则都钉死到边界：整 token 匹配、只认 ≥2 的季数、
 * 剥完主体为空就放弃拆分、识别失败原样留作关键词。它错了的表现不是报错，
 * 而是「搜索结果莫名其妙多/少一批」——比崩了更难发现。
 */
class SearchQueryTest {

    @Test
    @DisplayName("空输入：null / 空白都返回 null（走无关键词的列表路径）")
    void blankIsNull() {
        assertThat(SearchQuery.parse(null)).isNull();
        assertThat(SearchQuery.parse("   ")).isNull();
    }

    @Test
    @DisplayName("「2019年 动画」→ 年份 + 类型，关键词为空（不是把整串当关键词扫全表）")
    void yearAndType() {
        SearchQuery query = SearchQuery.parse("2019年 动画");

        assertThat(query.keyword()).isNull();
        assertThat(query.year()).isEqualTo(2019);
        assertThat(query.workType()).isEqualTo("anime");
    }

    @Test
    @DisplayName("「游戏王」不被拆成「游戏 + 王」：类型词是整 token 匹配")
    void typeWordIsWholeToken() {
        SearchQuery query = SearchQuery.parse("游戏王");

        assertThat(query.keyword()).isEqualTo("游戏王");
        assertThat(query.workType()).isNull();
    }

    @Test
    @DisplayName("「游戏 王」是两段：用户自己打了空格，才按类型 + 关键词拆")
    void typeWordWithSpace() {
        SearchQuery query = SearchQuery.parse("游戏 王");

        assertThat(query.workType()).isEqualTo("game");
        assertThat(query.keyword()).isEqualTo("王");
    }

    @Test
    @DisplayName("季数四种写法：第2季 / 第二期 / Ⅱ / 2nd，都识别成 2")
    void seasonVariants() {
        assertThat(SearchQuery.parse("进击的巨人 第2季").season()).isEqualTo(2);
        assertThat(SearchQuery.parse("进击的巨人 第二期").season()).isEqualTo(2);
        assertThat(SearchQuery.parse("进击的巨人 Ⅱ").season()).isEqualTo(2);
        assertThat(SearchQuery.parse("进击的巨人 2nd").season()).isEqualTo(2);
        assertThat(SearchQuery.parse("进击的巨人 Season 2").season()).isEqualTo(2);
    }

    @Test
    @DisplayName("季数贴在标题后面（没有空格）也能拆：进击的巨人第二期 → 关键词 + 季数")
    void seasonSuffixWithoutSpace() {
        SearchQuery query = SearchQuery.parse("进击的巨人第二期");

        assertThat(query.keyword()).isEqualTo("进击的巨人");
        assertThat(query.season()).isEqualTo(2);
    }

    @Test
    @DisplayName("只认 ≥2：第1季 / Ⅰ / 1st 不拆（歧义太大），原样留作关键词")
    void seasonOneIsNotParsed() {
        SearchQuery first = SearchQuery.parse("进击的巨人 第1季");
        assertThat(first.season()).isNull();
        assertThat(first.keyword()).isEqualTo("进击的巨人 第1季");

        assertThat(SearchQuery.parse("进击的巨人 Ⅰ").season()).isNull();
        assertThat(SearchQuery.parse("进击的巨人 1st").season()).isNull();
    }

    @Test
    @DisplayName("剥完主体为空就放弃拆分：只搜「第二期」仍按字面搜，不返回全库")
    void seasonOnlyFallsBackToRaw() {
        SearchQuery query = SearchQuery.parse("第二期");

        assertThat(query.keyword()).isEqualTo("第二期");
        assertThat(query.season()).isNull();
    }

    @Test
    @DisplayName("年份边界：1950–2049 内才认；1949 / 2050 原样当关键词")
    void yearRange() {
        assertThat(SearchQuery.parse("1950").year()).isEqualTo(1950);
        assertThat(SearchQuery.parse("2049年").year()).isEqualTo(2049);
        assertThat(SearchQuery.parse("1949").year()).isNull();
        assertThat(SearchQuery.parse("2050").year()).isNull();
        assertThat(SearchQuery.parse("1949").keyword()).isEqualTo("1949");
    }

    @Test
    @DisplayName("年份贴着标题：巨人2019 → 关键词 巨人 + 年份；长数字串不算（前后不能贴数字）")
    void yearSuffix() {
        SearchQuery query = SearchQuery.parse("进击的巨人2019");
        assertThat(query.keyword()).isEqualTo("进击的巨人");
        assertThat(query.year()).isEqualTo(2019);

        SearchQuery digits = SearchQuery.parse("12342019");
        assertThat(digits.year()).isNull();
        assertThat(digits.keyword()).isEqualTo("12342019");
    }

    @Test
    @DisplayName("识别失败原样保留：普通关键词一字不改（只放宽、不收紧）")
    void unknownTokensAreKept() {
        SearchQuery query = SearchQuery.parse("  Clannad   After Story ");

        assertThat(query.keyword()).isEqualTo("Clannad After Story");
        assertThat(query.year()).isNull();
        assertThat(query.workType()).isNull();
        assertThat(query.season()).isNull();
    }

    @Test
    @DisplayName("季数变体覆盖 6 种写法；没有季数时变体为空（不要拼出无关条件）")
    void titleVariants() {
        SearchQuery query = SearchQuery.parse("进击的巨人 第二期");

        assertThat(query.titleVariants())
                .contains("第2季", "第二季", "第二期", "Ⅱ", "ⅱ", "2nd", "Season 2");
        assertThat(SearchQuery.parse("进击的巨人").titleVariants()).isEmpty();
    }
}

package com.otaku.persona;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 九维口径的规则测试（#494）。
 *
 * <p>断言的是**口径与边界**，不是具体调参：样本不足给中性 50 而不是假缺角、贝叶斯平滑不被小样本
 * 顶满、完成度在全「看过」时不装成 100 —— 这些是语义，调参不该动它们。
 */
class PersonaDimensionsTest {

    private static final Set<String> GENRES = Set.of("机战", "奇幻", "恋爱", "悬疑", "治愈", "致郁");
    private static final int YEAR = 2026;

    @Test
    @DisplayName("没有任何作品时九维全是中性 50，不是 0")
    void emptyWorksGiveNeutral() {
        Map<String, Double> dims = PersonaDimensions.compute(List.of(), GENRES, YEAR);

        assertThat(dims.keySet()).containsExactlyElementsOf(PersonaDimensions.KEYS);
        assertThat(dims.values()).allMatch(v -> v == PersonaDimensions.NEUTRAL);
    }

    @Test
    @DisplayName("题材垂直：前 3 大题材覆盖了几成有标签的作品")
    void tagFocusIsTopThreeCoverage() {
        List<PersonaDimensions.DimWork> works = new ArrayList<>();
        for (int i = 0; i < 4; i++) {
            works.add(work(List.of("机战"), 2015, null, null, "watched"));
        }
        for (int i = 0; i < 3; i++) {
            works.add(work(List.of("奇幻"), 2015, null, null, "watched"));
        }
        for (int i = 0; i < 2; i++) {
            works.add(work(List.of("恋爱"), 2015, null, null, "watched"));
        }
        works.add(work(List.of("悬疑"), 2015, null, null, "watched"));

        // 10 部都有标签；top3 = 机战 4 / 奇幻 3 / 恋爱 2，共覆盖 9 部
        assertThat(PersonaDimensions.compute(works, GENRES, YEAR).get("tag_focus")).isEqualTo(90.0);
    }

    @Test
    @DisplayName("探索广度按密度算：只标了几部的人不会因为种类少就满分")
    void explorationIsDensityNotAbsoluteCount() {
        List<PersonaDimensions.DimWork> works = List.of(
                work(List.of("机战"), 2015, null, null, "watched"),
                work(List.of("奇幻"), 2015, null, null, "watched"),
                work(List.of("恋爱"), 2015, null, null, "watched"),
                work(List.of("悬疑"), 2015, null, null, "watched"));

        // distinct 4 / (4 + 100) * 100 = 3.85 种每百部 → / 25 = 15.4
        assertThat(PersonaDimensions.compute(works, GENRES, YEAR).get("exploration")).isEqualTo(15.4);
    }

    @Test
    @DisplayName("大众度与冷热跨度：样本不足 5 部给中性，够了才按百分位算")
    void heatDimensionsNeedFiveSamples() {
        List<PersonaDimensions.DimWork> four = List.of(
                work(List.of(), 2015, 8, 129L, "watched"),
                work(List.of(), 2015, 8, 129L, "watched"),
                work(List.of(), 2015, 8, 129L, "watched"),
                work(List.of(), 2015, 8, 129L, "watched"));

        Map<String, Double> thin = PersonaDimensions.compute(four, GENRES, YEAR);
        assertThat(thin.get("mainstream")).isEqualTo(50.0);
        assertThat(thin.get("pop_spread")).isEqualTo(50.0);

        List<PersonaDimensions.DimWork> five = new ArrayList<>(four);
        five.add(work(List.of(), 2015, 8, 129L, "watched"));

        // 129 人评分 → log10 ≈ 2.11，正好落在 50 分位锚点上；五部同热度 → 标准差 0
        Map<String, Double> enough = PersonaDimensions.compute(five, GENRES, YEAR);
        assertThat(enough.get("mainstream")).isEqualTo(50.0);
        assertThat(enough.get("pop_spread")).isEqualTo(0.0);
    }

    @Test
    @DisplayName("评分维度不拿原始占比：10 部全高分经平滑后是 72.7，不是 100")
    void qualityIsBayesSmoothed() {
        List<PersonaDimensions.DimWork> works = new ArrayList<>();
        for (int i = 0; i < 10; i++) {
            works.add(work(List.of(), 2015, 9, null, "watched"));
        }

        // (10 + 6) / (10 + 12) = 72.7%
        assertThat(PersonaDimensions.compute(works, GENRES, YEAR).get("quality")).isEqualTo(72.7);
    }

    @Test
    @DisplayName("年代跨度按年份标准差：挤在同一年是 0，铺开才涨")
    void eraSpanUsesYearStandardDeviation() {
        List<PersonaDimensions.DimWork> sameYear = new ArrayList<>();
        for (int i = 0; i < 5; i++) {
            sameYear.add(work(List.of(), 2020, null, null, "watched"));
        }
        assertThat(PersonaDimensions.compute(sameYear, GENRES, YEAR).get("era_span")).isEqualTo(0.0);

        List<PersonaDimensions.DimWork> spread = List.of(
                work(List.of(), 2000, null, null, "watched"),
                work(List.of(), 2001, null, null, "watched"),
                work(List.of(), 2002, null, null, "watched"),
                work(List.of(), 2003, null, null, "watched"),
                work(List.of(), 2004, null, null, "watched"));

        // 标准差 √2 ≈ 1.414 年 → / 12 年 = 11.8
        assertThat(PersonaDimensions.compute(spread, GENRES, YEAR).get("era_span")).isEqualTo(11.8);
    }

    @Test
    @DisplayName("追新度：近五年发行作品占比，样本不足 8 部不判")
    void freshnessCountsLastFiveYears() {
        List<PersonaDimensions.DimWork> works = new ArrayList<>();
        for (int i = 0; i < 4; i++) {
            works.add(work(List.of(), 2023, null, null, "watched"));
        }
        for (int i = 0; i < 4; i++) {
            works.add(work(List.of(), 2010, null, null, "watched"));
        }

        assertThat(PersonaDimensions.compute(works, GENRES, YEAR).get("fresh")).isEqualTo(50.0);

        List<PersonaDimensions.DimWork> thin = works.subList(0, 4);
        assertThat(PersonaDimensions.compute(thin, GENRES, YEAR).get("fresh")).isEqualTo(50.0);
    }

    @Test
    @DisplayName("情绪取向：只有治愈信号时不按情绪样本内占比顶满，按全部有标签作品算浓度")
    void emotionHandlesOneSidedSignals() {
        List<PersonaDimensions.DimWork> works = new ArrayList<>();
        for (int i = 0; i < 8; i++) {
            works.add(work(List.of("治愈"), 2015, null, null, "watched"));
        }
        for (int i = 0; i < 2; i++) {
            works.add(work(List.of("机战"), 2015, null, null, "watched"));
        }

        // 治愈 8 部 / 有标签 10 部 → 50 + 80，夹到 100
        assertThat(PersonaDimensions.compute(works, GENRES, YEAR).get("emotion")).isEqualTo(100.0);

        List<PersonaDimensions.DimWork> few = works.subList(0, 5);
        // 情绪样本 5 部 < 8 → 中性，不因为「全是治愈」就给高分
        assertThat(PersonaDimensions.compute(few, GENRES, YEAR).get("emotion")).isEqualTo(50.0);
    }

    @Test
    @DisplayName("完成度：全「看过」时给 50，不装成 100；在看算没看完")
    void completionIsNeutralWhenNothingIsUnseen() {
        List<PersonaDimensions.DimWork> allWatched = new ArrayList<>();
        for (int i = 0; i < 5; i++) {
            allWatched.add(work(List.of(), 2015, null, null, "watched"));
        }
        assertThat(PersonaDimensions.compute(allWatched, GENRES, YEAR).get("completion")).isEqualTo(50.0);

        List<PersonaDimensions.DimWork> mixed = new ArrayList<>(allWatched.subList(0, 3));
        mixed.add(work(List.of(), 2015, null, null, "watching"));
        mixed.add(work(List.of(), 2015, null, null, "want"));

        // 3 看过 / 5 部，剩下两部一个在看一个想看 → 60
        assertThat(PersonaDimensions.compute(mixed, GENRES, YEAR).get("completion")).isEqualTo(60.0);
    }

    @Test
    @DisplayName("没有题材白名单时题材类维度给中性，而不是判成 0")
    void missingGenreWhitelistIsNeutralNotZero() {
        List<PersonaDimensions.DimWork> works = List.of(
                work(List.of("机战"), 2015, null, null, "watched"),
                work(List.of("奇幻"), 2015, null, null, "watched"));

        Map<String, Double> dims = PersonaDimensions.compute(works, Set.of(), YEAR);

        assertThat(dims.get("tag_focus")).isEqualTo(50.0);
        assertThat(dims.get("exploration")).isEqualTo(50.0);
    }

    private static PersonaDimensions.DimWork work(
            List<String> tags, Integer year, Integer rating, Long ratingCount, String status) {
        return new PersonaDimensions.DimWork(tags, year, rating, ratingCount, status);
    }
}

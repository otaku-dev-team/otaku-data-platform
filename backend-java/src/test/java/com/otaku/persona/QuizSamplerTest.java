package com.otaku.persona;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 冷启动选题的分层口径测试（#492）。
 *
 * <p>断言的是**口径**而不是某一批具体作品：同 seed 稳定、题材保底铺得满、年份不扎堆、
 * 同系列只占一个名额。这些是语义，改分层比例时才该动。
 *
 * <p><b>不在这里跟 Python 版做逐位对照</b>：两边的随机数发生器不同（见
 * {@link QuizSampler} 类注释），同一 seed 抽出的本来就不是同一批。能对照的是「同一个 seed
 * 在本服务上反复请求一致」，那由第一个用例守。
 */
class QuizSamplerTest {

    private static final List<String> GENRES = List.of(
            "热血", "恋爱", "日常", "科幻", "奇幻", "治愈", "悬疑", "校园");

    @Test
    @DisplayName("同一个 seed 反复请求出同一份题面")
    void sameSeedSameWorks() {
        List<QuizSampler.Candidate> rows = pool();

        List<QuizSampler.Candidate> first = QuizSampler.sample(rows, 100, 7);
        List<QuizSampler.Candidate> second = QuizSampler.sample(rows, 100, 7);

        assertThat(first).containsExactlyElementsOf(second);
    }

    @Test
    @DisplayName("换一批（seed+1）换的是题面，不是顺序")
    void nextSeedGivesDifferentSet() {
        List<QuizSampler.Candidate> rows = pool();

        Set<String> first = ids(QuizSampler.sample(rows, 100, 7));
        Set<String> second = ids(QuizSampler.sample(rows, 100, 8));

        assertThat(second).isNotEqualTo(first);
        assertThat(second).hasSize(100);
    }

    @Test
    @DisplayName("题量按请求给足，且不重复")
    void fillsRequestedSizeWithoutDuplicates() {
        List<QuizSampler.Candidate> rows = pool();

        List<QuizSampler.Candidate> picked = QuizSampler.sample(rows, 100, 0);

        assertThat(picked).hasSize(100);
        assertThat(ids(picked)).hasSize(100);
    }

    @Test
    @DisplayName("只出动画，漫画游戏轻小说不进主题面")
    void onlyAnime() {
        List<QuizSampler.Candidate> rows = new ArrayList<>(pool());
        // 塞一批热度更高的非动画：如果抽样没锁类型，它们会顶掉动画
        for (int i = 0; i < 50; i++) {
            rows.add(new QuizSampler.Candidate("C-" + i, "漫画" + i, "comic", 2020,
                    999999 - i, null, List.of("热血")));
        }
        rows.sort(Comparator.comparing(QuizSampler.Candidate::ratingCount).reversed());

        List<QuizSampler.Candidate> picked = QuizSampler.sample(rows, 100, 0);

        assertThat(picked).isNotEmpty();
        assertThat(picked).allMatch(row -> "anime".equals(row.workType()));
    }

    @Test
    @DisplayName("8 个题材桶各有着落，不会全被热度头部吃掉")
    void genreBucketsAllCovered() {
        List<QuizSampler.Candidate> rows = pool();

        List<QuizSampler.Candidate> picked = QuizSampler.sample(rows, 100, 0);

        Set<String> hit = new HashSet<>();
        for (String genre : GENRES) {
            boolean any = picked.stream()
                    .anyMatch(row -> row.tags().contains(genre));
            if (any) {
                hit.add(genre);
            }
        }
        assertThat(hit).containsExactlyInAnyOrderElementsOf(GENRES);
    }

    @Test
    @DisplayName("年份三段都抽得到，不是清一色新番")
    void yearBucketsAllCovered() {
        List<QuizSampler.Candidate> rows = pool();

        List<QuizSampler.Candidate> picked = QuizSampler.sample(rows, 100, 0);

        assertThat(picked).anyMatch(row -> row.releaseYear() != null && row.releaseYear() <= 2009);
        assertThat(picked).anyMatch(row -> row.releaseYear() != null
                && row.releaseYear() >= 2010 && row.releaseYear() <= 2019);
        assertThat(picked).anyMatch(row -> row.releaseYear() != null && row.releaseYear() >= 2020);
    }

    @Test
    @DisplayName("同系列多季只占一个名额（标题归一 + 前缀聚类）")
    void seriesDeduplicated() {
        List<QuizSampler.Candidate> rows = new ArrayList<>();
        // 同一系列的 12 部，热度都最高；不放宽去重的话 100 道题里会出现 12 部进击的巨人
        String[] seasons = {"", " 第2季", " 第3季", " 第4季", " 最终季", " 剧场版",
                " 剧场版 后篇", " OAD", " 特别篇", " 第2季 第2部", " Season 3", " 总集篇"};
        for (int i = 0; i < seasons.length; i++) {
            rows.add(new QuizSampler.Candidate("A-" + i, "进击的巨人" + seasons[i], "anime",
                    2020, 900000 - i, null, List.of("热血")));
        }
        for (int i = 0; i < 300; i++) {
            rows.add(new QuizSampler.Candidate("B-" + i, "别的作品" + String.format("%03d", i), "anime",
                    2015, 50000 - i, null, List.of("恋爱")));
        }
        rows.sort(Comparator.comparing(QuizSampler.Candidate::ratingCount).reversed());

        List<QuizSampler.Candidate> picked = QuizSampler.sample(rows, 100, 0);

        long titans = picked.stream()
                .filter(row -> row.title().startsWith("进击的巨人"))
                .count();
        assertThat(titans).isLessThanOrEqualTo(1);
    }

    @Test
    @DisplayName("有 series_key 时按它去重，标题不同也算同系列")
    void seriesKeyWinsOverTitle() {
        List<QuizSampler.Candidate> rows = List.of(
                new QuizSampler.Candidate("A-1", "第一季", "anime", 2020, 9000, "shingeki", List.of("热血")));
        List<QuizSampler.Candidate> more = new ArrayList<>(rows);
        more.add(new QuizSampler.Candidate("A-2", "完全不同的标题", "anime", 2021, 8000,
                "shingeki", List.of("热血")));
        for (int i = 0; i < 200; i++) {
            more.add(new QuizSampler.Candidate("B-" + i, "作品" + String.format("%03d", i), "anime",
                    2015, 1000 - i, null, List.of("恋爱")));
        }
        more.sort(Comparator.comparing(QuizSampler.Candidate::ratingCount).reversed());

        List<QuizSampler.Candidate> picked = QuizSampler.sample(more, 100, 0);

        long sameSeries = picked.stream()
                .filter(row -> "shingeki".equals(row.seriesKey()))
                .count();
        assertThat(sameSeries).isLessThanOrEqualTo(1);
    }

    @Test
    @DisplayName("空候选返回空，不抛")
    void emptyPool() {
        assertThat(QuizSampler.sample(List.of(), 100, 0)).isEmpty();
    }

    @Test
    @DisplayName("题库不够时少给，不重复凑数")
    void smallPoolGivesFewer() {
        List<QuizSampler.Candidate> rows = List.of(
                new QuizSampler.Candidate("A-1", "甲", "anime", 2020, 5000, null, List.of("热血")),
                new QuizSampler.Candidate("A-2", "乙", "anime", 2021, 4000, null, List.of("恋爱")),
                new QuizSampler.Candidate("A-3", "丙", "anime", 2022, 3000, null, List.of("治愈")));

        List<QuizSampler.Candidate> picked = QuizSampler.sample(rows, 100, 0);

        assertThat(picked).hasSize(3);
        assertThat(ids(picked)).hasSize(3);
    }

    @Test
    @DisplayName("题量夹到边界，不会因 0 或负数崩掉")
    void sizeClamped() {
        List<QuizSampler.Candidate> rows = pool();

        assertThat(QuizSampler.sample(rows, 0, 0)).hasSize(QuizSampler.MIN_SIZE);
        assertThat(QuizSampler.sample(rows, -5, 0)).hasSize(QuizSampler.MIN_SIZE);
        assertThat(QuizSampler.sample(rows, 10_000, 0)).hasSize(QuizSampler.MAX_SIZE);
    }

    @Test
    @DisplayName("标题归一剥掉季/剧场版/总集篇后缀，保留正片名")
    void titleKeyStripsSuffixes() {
        assertThat(QuizSampler.seriesTitleKey("进击的巨人 第2季")).isEqualTo("进击的巨人");
        assertThat(QuizSampler.seriesTitleKey("进击的巨人 剧场版")).isEqualTo("进击的巨人");
        assertThat(QuizSampler.seriesTitleKey("进击的巨人 总集篇")).isEqualTo("进击的巨人");
        assertThat(QuizSampler.seriesTitleKey("SPY×FAMILY Season 2")).isEqualTo("spy×family");
        assertThat(QuizSampler.seriesTitleKey("  进击的巨人  ")).isEqualTo("进击的巨人");
    }

    @Test
    @DisplayName("前缀聚类要够长才算同系列，短标题不误合")
    void prefixMatchNeedsLength() {
        assertThat(QuizSampler.sameSeries("t:街角魔族", "t:街角魔族 2丁目")).isTrue();
        // "t:魔法" 去掉前缀只剩 2 个字，太容易误撞
        assertThat(QuizSampler.sameSeries("t:魔法", "t:魔法少女小圆")).isFalse();
    }

    // ---------- 构造样本 ----------

    /**
     * 480 部动画：8 个题材各 60 部，年份 1990–2029 均匀铺开，热度随序号递减。
     *
     * <p>标题用三位补零——`作品0-001` 与 `作品0-010` 不以对方为前缀，
     * 否则测试自己的数据就会被系列去重合掉，断言「给了 100 道」要失败。
     */
    private static List<QuizSampler.Candidate> pool() {
        List<QuizSampler.Candidate> rows = new ArrayList<>();
        for (int g = 0; g < GENRES.size(); g++) {
            for (int j = 0; j < 60; j++) {
                int year = 1990 + (j % 40);
                rows.add(new QuizSampler.Candidate(
                        "W-" + g + "-" + j,
                        "作品" + g + "-" + String.format("%03d", j),
                        "anime",
                        year,
                        10000 - rows.size() / 8,
                        null,
                        List.of(GENRES.get(g))));
            }
        }
        rows.sort(Comparator.comparing(QuizSampler.Candidate::ratingCount).reversed());
        return rows;
    }

    private static Set<String> ids(List<QuizSampler.Candidate> rows) {
        Set<String> ids = new HashSet<>();
        for (QuizSampler.Candidate row : rows) {
            ids.add(row.workId());
        }
        return ids;
    }
}

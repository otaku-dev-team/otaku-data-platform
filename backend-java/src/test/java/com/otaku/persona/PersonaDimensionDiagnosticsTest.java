package com.otaku.persona;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Random;
import java.util.Set;
import java.util.function.Predicate;
import java.util.stream.Collectors;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 九维区分度诊断（#497）：**它能不能把不同口味的人分开**。
 *
 * <h2>为什么用构造样本，而不是真实用户</h2>
 *
 * #497 原写「取一批真实样本」，但生产此刻只有 4 个账号、**0 条收藏**——没有可诊断的行为数据。
 * 所以换一个问法：**给一批「口味已知且刻意拉开」的用户，九维能不能把他们分开**。
 * 这是构念效度（construct validity）的测法——如果连已知差异都分不开，真实用户来了只会更糟；
 * 反过来，塌缩就只可能来自口径或维度设计。
 *
 * <p>样本不是随手编的：年份按生产 decade 计数配比、评分人数取生产分位
 * （P10=23 / P50=147 / P90=2266）、治愈+致郁标签覆盖率按生产实测 **8.2%**
 * （作品级 1,445 / 17,524）撒。所以绝对量级有据可查，不是实验室数据。
 *
 * <p><b>8.2% 而不是 22.3%</b>：早先那次统计用的是 `work_tag` 的**标签行数**除以作品总数，
 * 而一部作品常同时挂「治愈」「温馨」「萌」，行数天然是作品数的两三倍。
 * 算法读的是 `work.tags` 这个 JSON 列，所以基础率必须按作品数算。
 *
 * <h2>读这个测试</h2>
 *
 * 断言分两类，注释里也分开写：
 * <ul>
 *   <li><b>方向断言</b>：「主流厨的大众度必须比冷门挖掘机高 30 分」这类——它们是语义，
 *       调参不该动；</li>
 *   <li><b>现状钉住</b>：已知缺陷（如「单一题材的探索广度反而更高」）用断言把**当前行为**钉住，
 *       修好那天必须同步改这里，改动会出现在 diff 里而不是悄悄漂走。</li>
 * </ul>
 */
class PersonaDimensionDiagnosticsTest {

    /** 24 个题材。为什么这么多：只有 5–6 个时「前 3 题材覆盖率」天然 50% 起步，测不出区分度。 */
    private static final List<String> GENRES = List.of(
            "机战", "奇幻", "恋爱", "悬疑", "治愈", "致郁", "日常", "热血", "科幻", "恐怖",
            "校园", "后宫", "运动", "音乐", "美食", "历史", "战争", "推理", "搞笑", "剧情",
            "百合", "耽美", "冒险", "萌系");
    private static final Set<String> GENRE_SET = Set.copyOf(GENRES);
    /** 非题材标签：真实 work.tags 里大部分是公司/角色/媒介，题材只有一两个。 */
    private static final List<String> NOISE = List.of("TV", "剧场版", "漫画原作", "原创", "轻小说");
    private static final int CURRENT_YEAR = 2026;

    /** 生产 decade 计数：80s 594 / 90s 1338 / 00s 4271 / 10s 7434 / 20s 4245。 */
    private static final int[] YEARS = {1986, 1992, 1998, 2004, 2010, 2016, 2022, 2025};
    /** 生产 rating_count 分位：P10=23 / P25=52 / P50=147 / P75=618 / P90=2266。 */
    private static final long[] POPULARITY = {23, 52, 147, 618, 2266, 8000};
    /** 治愈+致郁覆盖率 8.25%（作品级实测：1,445 / 17,524）。 */
    private static final double HEALING_DARK_SHARE = 0.0825;
    /** 情绪标签内部配比：治愈 76.4% / 致郁 23.6%（生产 1,118 : 346）。 */
    private static final double HEALING_WITHIN_EMOTION = 0.764;

    private static final int USERS_PER_ARCHETYPE = 10;
    /** 两种规模：12 部（轻度用户 / 刚导入）与 60 部（活跃用户）。 */
    private static final int[] COLLECTION_SIZES = {12, 60};

    @Test
    @DisplayName("区分度诊断：已知口味的用户，九维必须分得开（含两种收藏规模）")
    void dimensionsSeparateKnownArchetypes() {
        Map<Integer, Map<String, List<Map<String, Double>>>> bySize = new LinkedHashMap<>();
        for (int size : COLLECTION_SIZES) {
            bySize.put(size, runCohort(size));
        }

        // ---- 方向断言：在「活跃用户」（60 部）上看，避开小样本噪声 ----
        Map<String, List<Map<String, Double>>> engaged = bySize.get(60);
        Map<String, Double> average = archetypeMeans(engaged, "博爱·六边形");
        Map<String, Double> picky = archetypeMeans(engaged, "偏食·机战");
        Map<String, Double> mainstream = archetypeMeans(engaged, "主流厨");
        Map<String, Double> obscure = archetypeMeans(engaged, "冷门挖掘机");
        Map<String, Double> chaseNew = archetypeMeans(engaged, "追新党");
        Map<String, Double> archaeology = archetypeMeans(engaged, "考古党");
        Map<String, Double> masterpieces = archetypeMeans(engaged, "神作党");
        Map<String, Double> healing = archetypeMeans(engaged, "治愈系");
        Map<String, Double> dark = archetypeMeans(engaged, "致郁系");
        Map<String, Double> binge = archetypeMeans(engaged, "完播党");
        Map<String, Double> hamster = archetypeMeans(engaged, "仓鼠党");

        assertThat(picky.get("tag_focus"))
                .as("题材集中度：偏食必须明显高于博爱")
                .isGreaterThan(average.get("tag_focus") + 20);
        assertThat(mainstream.get("mainstream"))
                .as("大众度：主流厨必须远高于冷门挖掘机")
                .isGreaterThan(obscure.get("mainstream") + 30);
        assertThat(chaseNew.get("fresh"))
                .as("追新度：追新党必须明显高于考古党")
                .isGreaterThan(archaeology.get("fresh") + 30);
        assertThat(masterpieces.get("quality"))
                .as("口碑分：神作党必须明显高于平均")
                .isGreaterThan(average.get("quality") + 15);
        assertThat(healing.get("emotion"))
                .as("情绪取向：治愈系必须明显偏高")
                .isGreaterThan(average.get("emotion") + 15);
        assertThat(dark.get("emotion"))
                .as("情绪取向的另一端：致郁系必须明显偏低（只有基础率归一之后才成立）")
                .isLessThan(average.get("emotion") - 15);
        assertThat(average.get("emotion"))
                .as("与全站配比相近的人必须落在中性附近——修前这里是 76，测的是全站标签分布而非个人口味")
                .isCloseTo(PersonaDimensions.NEUTRAL, org.assertj.core.data.Offset.offset(10.0));
        assertThat(binge.get("completion"))
                .as("完成度：完播党必须远高于仓鼠党")
                .isGreaterThan(hamster.get("completion") + 30);

        assertThat(picky.get("exploration"))
                .as("探索广度：偏食必须低于博爱（24 题材、真实标签配比下方向是对的）")
                .isLessThan(average.get("exploration") - 20);

        // ---- 轻度用户（12 部）：旧口径下情绪维恒 50（命中 ≥8 部的概率 0.04%），现在必须还能分开 ----
        Map<String, List<Map<String, Double>>> light = bySize.get(12);
        assertThat(archetypeMeans(light, "治愈系").get("emotion"))
                .as("12 部也要分得开：这是「门槛 8」最致命的场景")
                .isGreaterThan(archetypeMeans(light, "博爱·六边形").get("emotion") + 15);

        // ---- 已知取舍：用断言钉住现状，改主意那天必须改这里 ----
        assertThat(binge.get("completion"))
                .as("**已知取舍**：全「看过」按中性 50 处理（防止数据源天然全 watched 时假装 100），"
                        + "代价是「完美完播」与「没有完成度信号」在界面上同值")
                .isEqualTo(PersonaDimensions.NEUTRAL);

        // ---- 塌缩底线：每根轴在人群里都得有可见离散度 ----
        for (String key : PersonaDimensions.KEYS) {
            List<Double> all = engaged.values().stream()
                    .flatMap(List::stream).map(p -> p.get(key)).toList();
            double std = std(all);
            assertThat(std)
                    .as("维度 %s 的跨人群标准差只有 %.1f：所有人挤在 50 附近，这根轴等于没起作用",
                            key, std)
                    .isGreaterThan(5.0);
        }
    }

    @Test
    @DisplayName("边界已修：只碰一个题材给最低档 10，不再比博爱还高")
    void singleGenreGetsLowestExploration() {
        List<PersonaDimensions.DimWork> onlyOneGenre = new ArrayList<>();
        for (int i = 0; i < 12; i++) {
            onlyOneGenre.add(new PersonaDimensions.DimWork(
                    List.of("机战", "TV"), 2015, null, null, "watched"));
        }

        Map<String, Double> dims = PersonaDimensions.compute(onlyOneGenre, GENRE_SET, CURRENT_YEAR);

        // 修前是 NEUTRAL（50），语义上「只碰一个题材」是最偏食的极端却比 24 题材里
        // 随便看的人（≈57）还高。现在 distinctGenres==1 → 10，只有 ==0 才给中性。
        assertThat(dims.get("exploration")).isEqualTo(PersonaDimensions.EXPLORATION_SINGLE_GENRE);

        // 「没有题材数据」仍必须是中性：否则白名单没配的账号会被判成偏食
        List<PersonaDimensions.DimWork> noGenre = new ArrayList<>();
        for (int i = 0; i < 12; i++) {
            noGenre.add(new PersonaDimensions.DimWork(
                    List.of("TV", "漫画原作"), 2015, null, null, "watched"));
        }
        assertThat(PersonaDimensions.compute(noGenre, GENRE_SET, CURRENT_YEAR).get("exploration"))
                .as("全是公司/媒介标签 → 不知道口味，给中性")
                .isEqualTo(PersonaDimensions.NEUTRAL);
    }

    // ---------------------------------------------------------------- 人群

    private static Map<String, List<Map<String, Double>>> runCohort(int worksPerUser) {
        List<CatalogWork> catalog = catalog();
        Map<String, List<Map<String, Double>>> byArchetype = new LinkedHashMap<>();
        for (Archetype archetype : archetypes()) {
            List<Map<String, Double>> profiles = new ArrayList<>();
            Random random = new Random(42L);
            for (int u = 0; u < USERS_PER_ARCHETYPE; u++) {
                profiles.add(PersonaDimensions.compute(
                        archetype.pick(catalog, random, worksPerUser), GENRE_SET, CURRENT_YEAR));
            }
            byArchetype.put(archetype.name(), profiles);
        }
        System.out.println(render(byArchetype, worksPerUser));
        return byArchetype;
    }

    /**
     * 虚拟目录：24 题材 × 8 年代 × 6 热度 × 2 口碑 = 2,304 部，另按 8.25% 配比撒治愈/致郁标签。
     *
     * <p>每部只挂 1 个题材 + 1 个噪声标签：真实 `work.tags` 平均 8–12 个，但绝大多数是公司/角色/媒介，
     * 真正算题材的一两个。按「题材 1 + 噪声 1」建，才能让 tag_focus 测的是题材集中而不是标签总数。
     */
    private static List<CatalogWork> catalog() {
        List<CatalogWork> works = new ArrayList<>();
        int i = 0;
        for (String genre : GENRES) {
            for (int year : YEARS) {
                for (long popularity : POPULARITY) {
                    for (boolean masterpiece : new boolean[]{true, false}) {
                        works.add(new CatalogWork(
                                new ArrayList<>(List.of(genre, NOISE.get(i++ % NOISE.size()))),
                                year,
                                masterpiece ? 8 : 6,
                                popularity,
                                "watched"));
                    }
                }
            }
        }
        // 按生产比例撒「情绪标签」：8.25% 的作品带治愈或致郁（治愈:致郁 ≈ 76:24，同生产 1,118:346）
        Random random = new Random(7L);
        int tagged = (int) Math.round(works.size() * HEALING_DARK_SHARE);
        List<CatalogWork> shuffled = new ArrayList<>(works);
        java.util.Collections.shuffle(shuffled, random);
        for (int k = 0; k < tagged; k++) {
            shuffled.get(k).tags().add(
                    random.nextDouble() < HEALING_WITHIN_EMOTION ? "治愈" : "致郁");
        }
        return works;
    }

    /** 目录里的一条。tags 可变：撒情绪标签时直接往里加。 */
    private record CatalogWork(List<String> tags, Integer year, Integer rating,
                               Long ratingCount, String status) {
    }

    private record Archetype(String name, Predicate<CatalogWork> filter, String status) {
        List<PersonaDimensions.DimWork> pick(List<CatalogWork> catalog, Random random, int count) {
            List<CatalogWork> pool = catalog.stream().filter(filter).collect(Collectors.toList());
            List<PersonaDimensions.DimWork> picked = new ArrayList<>(count);
            for (int i = 0; i < count; i++) {
                CatalogWork work = pool.get(random.nextInt(pool.size()));
                picked.add(new PersonaDimensions.DimWork(work.tags(), work.year(), work.rating(),
                        work.ratingCount(), status));
            }
            return picked;
        }
    }

    private static List<Archetype> archetypes() {
        return List.of(
                new Archetype("偏食·机战", w -> w.tags().contains("机战"), "watched"),
                new Archetype("博爱·六边形", w -> true, "watched"),
                new Archetype("主流厨", w -> w.ratingCount() >= 2000, "watched"),
                new Archetype("冷门挖掘机", w -> w.ratingCount() <= 52, "watched"),
                new Archetype("追新党", w -> w.year() >= CURRENT_YEAR - 4, "watched"),
                new Archetype("考古党", w -> w.year() <= 2004, "watched"),
                new Archetype("神作党", w -> w.rating() >= 8, "watched"),
                new Archetype("治愈系", w -> w.tags().contains("治愈"), "watched"),
                new Archetype("致郁系", w -> w.tags().contains("致郁"), "watched"),
                new Archetype("完播党", w -> true, "watched"),
                new Archetype("仓鼠党", w -> true, "want"));
    }

    // ---------------------------------------------------------------- 统计

    private static Map<String, Double> archetypeMeans(
            Map<String, List<Map<String, Double>>> byArchetype, String name) {
        List<Map<String, Double>> profiles = byArchetype.get(name);
        Map<String, Double> means = new LinkedHashMap<>();
        for (String key : PersonaDimensions.KEYS) {
            means.put(key, profiles.stream().mapToDouble(p -> p.get(key)).average().orElse(0));
        }
        return means;
    }

    private static double std(List<Double> values) {
        double mean = values.stream().mapToDouble(Double::doubleValue).average().orElse(0);
        double variance = values.stream()
                .mapToDouble(v -> (v - mean) * (v - mean))
                .sum() / Math.max(1, values.size());
        return Math.sqrt(variance);
    }

    /** 一张可直接贴进诊断报告的竖表：行 = 维度，列 = 人群。 */
    private static String render(Map<String, List<Map<String, Double>>> byArchetype, int size) {
        List<String> names = new ArrayList<>(byArchetype.keySet());
        StringBuilder out = new StringBuilder(
                "\n九维区分度 · 每人 %d 部 · %d 人/类\n".formatted(size, USERS_PER_ARCHETYPE));
        out.append("| 维度 | 均值 | 标准差 |");
        names.forEach(name -> out.append(' ').append(name).append(" |"));
        out.append("\n|---|---|---|");
        names.forEach(name -> out.append("---|"));
        out.append('\n');
        for (String key : PersonaDimensions.KEYS) {
            List<Double> all = byArchetype.values().stream()
                    .flatMap(List::stream).map(p -> p.get(key)).toList();
            double mean = all.stream().mapToDouble(Double::doubleValue).average().orElse(0);
            out.append("| `%s` | %.1f | %.1f |".formatted(key, mean, std(all)));
            for (String name : names) {
                out.append(" %.0f |".formatted(archetypeMeans(byArchetype, name).get(key)));
            }
            out.append('\n');
        }
        return out.toString();
    }
}

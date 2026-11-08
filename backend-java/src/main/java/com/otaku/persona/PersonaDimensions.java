package com.otaku.persona;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.stream.Collectors;

/**
 * 九维画像的纯函数实现（#494 第一版）。
 *
 * <p>口径从网站 {@code app/persona.py}（{@code DIMENSION_VERSION = 4}）移植，每个维度的
 * 阈值与说明都与那边一一对应，改任一处都要两边同步并在 {@link #DIMENSION_VERSION} 上 +1。
 *
 * <p><b>这一版只算分，不接契约</b>：{@code GET /api/me/profile} 的 {@code dimensions} 字段、
 * {@code hero_*} / {@code trait_blurbs} 等留给接线那一步，避免把「算法」和「跨模块数据结构」
 * 两件事塞进同一个 PR。
 *
 * <p>三个与网站刻意的差异：
 * <ol>
 *   <li><b>缺失一律给 50，不给 0</b>。网站部分维度在样本不足时返回 {@code 0.0}，客户端会把它
 *       画成雷达上的一个凹角，看起来像「你这方面很弱」，其实是「还没数据」。这里统一走
 *       {@link #NEUTRAL}。</li>
 *   <li><b>完成度不用补 watching</b>。网站的「在看」要靠 B 站 {@code follow_status} 反推，
 *       otaku 的 collection 本来就有 {@code watching}，直接读。</li>
 *   <li><b>热度只看一个源</b>。网站要按 {@code SOURCE_HEAT_FACTOR} 把 Bangumi / B 站折算到
 *       站内口径；otaku 只有一份 {@code rating_count}，不需要折算。</li>
 * </ol>
 */
public final class PersonaDimensions {

    private PersonaDimensions() {
    }

    /**
     * 维度口径版本号：改任一维度的算法或阈值时 +1。
     *
     * <p>**5 与网站的 4 不是同一个口径**：这一版在移植基线（4）上修了两处本地缺陷——
     * 探索广度的单题材边界、情绪取向的基础率归一（见 {@code emotion} 与 {@code exploration}）。
     * 两处都记在 {@code docs/persona-dimension-diagnostics.md} 的修复记录里，
     * 网站同步后版本号再合并；在那之前别拿两个 5 / 4 直接对比数值。
     */
    public static final int DIMENSION_VERSION = 5;

    /** 九维的键序，与 #490 表格、网站 {@code DIMENSION_LABELS} 一致。 */
    public static final List<String> KEYS = List.of(
            "tag_focus", "exploration", "mainstream", "pop_spread", "quality",
            "era_span", "fresh", "emotion", "completion");

    /** 中性值：数据不足的维度画在这里，而不是 0。 */
    public static final double NEUTRAL = 50.0;

    /** 样本门槛：热度、年代、跨度的标准差类维度，少于 5 部说明不了分布。 */
    static final int MIN_SAMPLE = 5;
    /**
     * 情绪取向的**生产基础配比**（作品级，2026-11-08 实测）。
     *
     * <p>分母是「有标签的作品」17,524 部：治愈 1,118（6.4%）、致郁 346（2.0%）、任一 1,445（8.2%）。
     * 两处口径都要留意：
     * <ul>
     *   <li>这是 {@code work.tags} JSON 的实测值——也就是算法真正的输入；
     *       按 {@code work_tag} 表数「标签行」会得到 22.3%，那是行数不是作品数（一部作品常挂两个治愈标签），
     *       用它当基础率会把密度高估近三倍；</li>
     *   <li>比例是 **治愈:致郁 = 76:24**，不是 85:15——平均口味的用户本身就偏治愈，
     *       所以「全站平均」必须落在 50，不能默认 0。</li>
     * </ul>
     */
    static final double EMOTION_HEALING_SHARE = 0.764;
    static final double EMOTION_DARK_SHARE = 0.236;
    /**
     * 情绪取向的收缩强度：相当于先塞进 4 部「平均口味」的作品再算比例。
     *
     * <p>不设硬门槛（原先是「命中 ≥8 部才给分」）：治愈/致郁只占 8.2%，
     * 12 部收藏命中 8 部的概率约万分之四，轻度用户永远拿中性 50；而 60 部时人人命中 5 部左右，
     * 又变成「全站配比的镜子」。平滑让小样本自然回到 50、大样本才敢偏离，不需要门槛。
     */
    static final double EMOTION_PRIOR_WEIGHT = 4.0;
    /** 基础取向值：+1 = 全治愈、-1 = 全致郁，0.528 = 与全站同配比。 */
    static final double EMOTION_BASE_ORIENTATION = EMOTION_HEALING_SHARE - EMOTION_DARK_SHARE;
    /** 追新度门槛：只收藏两三部当季番不能判成「硬核追新党」。 */
    static final int FRESH_MIN_SAMPLE = 8;

    /** 题材密度：每百部覆盖 25 种即满分。 */
    static final double EXPLORATION_SMOOTH = 100.0;
    static final double EXPLORATION_DENSITY_REF = 25.0;
    /**
     * 只碰过一个题材：探索广度的最低档，给 10 而不是中性 50。
     *
     * <p>原先 {@code distinctGenres <= 1} 与「没有题材数据」共用一个中性分支，结果是
     * 「只吃机战」比「24 个题材各看一点」（约 57）还像博爱——最偏食的极端拿到了最高档。
     * 50 只能留给「不知道」（没有白名单 / 作品无题材标签）。
     */
    static final double EXPLORATION_SINGLE_GENRE = 10.0;
    /** 年代跨度：标准差达到 12 年记满分。 */
    static final double ERA_SPAN_REF = 12.0;
    /** 冷热跨度：百分位标准差达到 25 记满分。 */
    static final double POP_SPREAD_REF = 25.0;
    /** 追新窗口：近五年（含今年）。 */
    static final int FRESH_YEARS = 5;
    /** 高分率：评分 ≥7 算高分，贝叶斯先验 12 部 / 6 部高分（equivalent to 50%）。 */
    static final int QUALITY_FROM = 7;
    static final int QUALITY_PRIOR_HITS = 6;
    static final int QUALITY_PRIOR_TOTAL = 12;

    /** 情绪取向的标签集合，与网站 HEALING_TAGS / DARK_TAGS 对齐。 */
    static final Set<String> HEALING_TAGS = Set.of("治愈", "治愈系", "温馨", "空气系", "萌", "萌系");
    static final Set<String> DARK_TAGS = Set.of("致郁", "沉重", "黑深残", "猎奇", "扭曲");

    /**
     * 热度分位锚点：{@code log10(rating_count)} → 站内百分位。
     *
     * <p>取自网站对 18,828 部快照的经验分位（P50 ≈ 129 人评分）。换成固定公式会在
     * 量纲不同的数据源上崩掉，所以这里保留「查表 + 线性插值」。
     */
    static final double[][] POP_ANCHORS = {
            {0.00, 0.0}, {1.32, 10.0}, {1.62, 25.0}, {2.11, 50.0},
            {2.75, 75.0}, {3.32, 90.0}, {4.62, 100.0},
    };

    /**
     * 一条参与画像计算的作品。
     *
     * @param tags        作品标签（原样传入，题材判定由 {@code genreTags} 决定）
     * @param year        发行年，可空
     * @param rating      归一化后的 1–10 分，可空（可空 = 未评分，不参与高分率）
     * @param ratingCount 评价人数，可空（可空 = 不参与热度维度）
     * @param status      收藏状态：want / watching / watched / dropped / null（null 视作「想看」，
     *                    与 {@code PersonaService} 现有的 COLLECTION_UNSET 口径一致；
     *                    {@code dropped} 是「抛弃」，完成度与题材版图都不计它）
     */
    public record DimWork(
            List<String> tags,
            Integer year,
            Integer rating,
            Long ratingCount,
            String status) {

        public DimWork {
            tags = tags == null ? List.of() : List.copyOf(tags);
        }
    }

    /**
     * 算九个维度。
     *
     * @param works       参与计算的作品（调用方已按「收藏 / 浏览」筛好）
     * @param genreTags   题材标签白名单，决定哪些标签算「题材」
     * @param currentYear 当前年份，追新度用它算五年窗口（不取系统时钟，方便测试固定）
     */
    public static Map<String, Double> compute(
            List<DimWork> works, Set<String> genreTags, int currentYear) {

        List<DimWork> safeWorks = works == null ? List.of() : works;
        Map<String, Integer> genreCounts = genreCounts(safeWorks, genreTags);

        Map<String, Double> dims = new LinkedHashMap<>();
        dims.put("tag_focus", tagFocus(safeWorks, genreCounts));
        dims.put("exploration", exploration(safeWorks.size(), genreCounts.size()));
        dims.put("mainstream", mainstream(safeWorks));
        dims.put("pop_spread", popSpread(safeWorks));
        dims.put("quality", quality(safeWorks));
        dims.put("era_span", eraSpan(safeWorks));
        dims.put("fresh", freshness(safeWorks, currentYear));
        dims.put("emotion", emotion(safeWorks));
        dims.put("completion", completion(safeWorks));
        return dims;
    }

    /**
     * 题材垂直：最爱的前 3 个题材**覆盖了多少部有标签的作品**（0–100）。
     *
     * <p>按作品计数而不是按标签次数：同一份口味，B 站每部约 2 个 styles、Bangumi 每部 8–10 个
     * 标签，按次数算会得出两个差 15 分的数字（网站 2026-10-30 实测）。
     */
    static double tagFocus(List<DimWork> works, Map<String, Integer> genreCounts) {
        if (genreCounts.isEmpty()) {
            return NEUTRAL;
        }
        Set<String> top3 = genreCounts.entrySet().stream()
                .sorted(Map.Entry.<String, Integer>comparingByValue(Comparator.reverseOrder())
                        .thenComparing(Map.Entry.comparingByKey()))
                .limit(3)
                .map(Map.Entry::getKey)
                .collect(Collectors.toSet());

        List<DimWork> tagged = works.stream().filter(w -> !w.tags().isEmpty()).toList();
        if (tagged.isEmpty()) {
            return NEUTRAL;
        }
        long covered = tagged.stream().filter(w -> w.tags().stream().anyMatch(top3::contains)).count();
        return round((double) covered / tagged.size() * 100);
    }

    /**
     * 探索广度：题材密度——每百部作品覆盖多少种题材（0–100）。
     *
     * <p>平滑项 {@value #EXPLORATION_SMOOTH} 相当于「先验 100 部作品」，防止「只标了 10 部却有
     * 10 种题材」直接拿满分。绝对种类数口径在网站踩过坑：500 部账号在密集标签下覆盖 100+ 种，
     * 六个账号全顶满。
     */
    static double exploration(int total, int distinctGenres) {
        if (total <= 0 || distinctGenres == 0) {
            // 0 = 没有题材数据（白名单为空、或作品全都没题材标签）→ 「不知道」，给中性。
            return NEUTRAL;
        }
        if (distinctGenres == 1) {
            // 1 = 确实只有一个题材 → 最偏食的极端，不能再和「不知道」共用 50。
            return EXPLORATION_SINGLE_GENRE;
        }
        double density = distinctGenres / (total + EXPLORATION_SMOOTH) * 100;
        return round(Math.min(100.0, density / EXPLORATION_DENSITY_REF * 100));
    }

    /** 大众度：收藏热度的站内百分位均值。读作「我收藏的作品在全站排到第几成」。 */
    static double mainstream(List<DimWork> works) {
        List<Double> percentiles = percentiles(works);
        if (percentiles.size() < MIN_SAMPLE) {
            return NEUTRAL;
        }
        return round(mean(percentiles));
    }

    /**
     * 冷热跨度：热度百分位的标准差，归一到 {@value #POP_SPREAD_REF}。
     *
     * <p>与大众度互补：大众度看偏主流还是偏冷门，跨度看是只吃一个热度带还是冷热通吃。
     */
    static double popSpread(List<DimWork> works) {
        List<Double> percentiles = percentiles(works);
        if (percentiles.size() < MIN_SAMPLE) {
            return NEUTRAL;
        }
        return round(Math.min(100.0, stdDev(percentiles) / POP_SPREAD_REF * 100));
    }

    /**
     * 高分率：评分 ≥7 的占比，贝叶斯平滑（先验 12 部、50 部里 6 部高分）。
     *
     * <p>不做平滑的话「10 部全 9 分」会直接顶到 100，看起来比「300 部里 80% 高分」还强。
     */
    static double quality(List<DimWork> works) {
        List<Integer> scored = works.stream()
                .map(DimWork::rating)
                .filter(r -> r != null)
                .toList();
        if (scored.isEmpty()) {
            return NEUTRAL;
        }
        long high = scored.stream().filter(r -> r >= QUALITY_FROM).count();
        return round((high + QUALITY_PRIOR_HITS) / (double) (scored.size() + QUALITY_PRIOR_TOTAL) * 100);
    }

    /**
     * 年代跨度：收藏年份的标准差，归一到 {@value #ERA_SPAN_REF} 年 = 100。
     *
     * <p>不用「去重年代数 / 6」：那个口径只有 6 个离散取值，网站实测 28 个账号里 11 个同分 66.7，
     * 等于没有分辨率。
     */
    static double eraSpan(List<DimWork> works) {
        List<Integer> years = works.stream()
                .map(DimWork::year)
                .filter(y -> y != null)
                .toList();
        if (years.size() < MIN_SAMPLE) {
            return NEUTRAL;
        }
        List<Double> values = years.stream().map(Integer::doubleValue).toList();
        return round(Math.min(100.0, stdDev(values) / ERA_SPAN_REF * 100));
    }

    /**
     * 追新度：近五年发行的作品占有年份作品的比例（0–100）。
     *
     * <p>替代「追更强度」：数据源拿不到可信的「正在追」信号，网站实测某账号 385 条在看算出来是 0。
     * 窗口取五年而不是两年，两年太窄，只收了几部当季番的人会被判成「几乎不追新」。
     */
    static double freshness(List<DimWork> works, int currentYear) {
        List<Integer> years = works.stream()
                .map(DimWork::year)
                .filter(y -> y != null)
                .toList();
        if (years.size() < FRESH_MIN_SAMPLE) {
            return NEUTRAL;
        }
        int cutoff = currentYear - (FRESH_YEARS - 1);
        long recent = years.stream().filter(y -> y >= cutoff).count();
        return round((double) recent / years.size() * 100);
    }

    /**
     * 情绪取向：治愈系 ↔ 致郁系，50 = **与全站配比一致**（治愈:致郁 ≈ 76:24）或无信号。
     *
     * <p>算法是「相对基础率的偏离」，不是「治愈占比」：
     * <ol>
     *   <li>取向值 {@code oriented}：在情绪标签内部算 {@code (治愈 - 致郁) / 并集}，
     *       取值 -1（全暗）… +1（全治愈）；</li>
     *   <li>用 {@value #EMOTION_PRIOR_WEIGHT} 部「平均口味」的伪计数把它收缩到
     *       {@link #EMOTION_BASE_ORIENTATION}，小样本自然回到 50；</li>
     *   <li>再按「偏离基础率多少」映射到 0–100（{@link #emotionScore}）。</li>
     * </ol>
     *
     * <p>两条都是踩过的坑：<b>按治愈占比直接加分</b>会让随手收藏的人拿 70+（测的是全站标签分布）；
     * <b>设「命中 ≥8 部」的硬门槛</b>会让 12 部收藏的轻度用户永远拿 50（治愈+致郁只占 8.25%，
     * 命中 8 部的概率约万分之四）。分母也不退回「全部有标签作品」——那会把
     * 「收藏多但没几部情绪番」压成「偏暗」，读起来像口味，其实只是标签铺得薄。
     */
    static double emotion(List<DimWork> works) {
        List<DimWork> tagged = works.stream().filter(w -> !w.tags().isEmpty()).toList();
        if (tagged.isEmpty()) {
            return NEUTRAL;
        }
        long healing = tagged.stream().filter(w -> hits(w, HEALING_TAGS)).count();
        long dark = tagged.stream().filter(w -> hits(w, DARK_TAGS)).count();
        long union = tagged.stream().filter(w -> hits(w, HEALING_TAGS) || hits(w, DARK_TAGS)).count();
        if (union == 0) {
            // 一部情绪标签都没有 → 无从判断取向，中性。
            return NEUTRAL;
        }
        // 先算「在情绪标签内部」的取向（-1 全暗 … +1 全治愈），再用 4 部伪计数收缩到全站配比。
        // 分母用 union 而不是「有标签的作品数」：后者会把「收藏多但没几部情绪番」的人
        // 压到 50 以下，读起来像「偏暗」，其实只是标签铺得薄。
        double oriented = (healing - dark + EMOTION_PRIOR_WEIGHT * EMOTION_BASE_ORIENTATION)
                / (union + EMOTION_PRIOR_WEIGHT);
        return round(emotionScore(oriented));
    }

    /**
     * 取向值 → 0–100：**与全站同配比 = 50**，全治愈 = 100，全致郁 = 0。
     *
     * <p>为什么必须扣掉基础率：治愈标签本来就比致郁常见（76:24），按「治愈占比」
     * 直接往上加，会让一个随手收藏的用户也拿到 70+——那测的是全站标签分布，不是这个人的选择。
     */
    private static double emotionScore(double oriented) {
        double base = EMOTION_BASE_ORIENTATION;
        double delta = oriented >= base
                ? (oriented - base) / (1 - base) * NEUTRAL
                : (oriented - base) / (base + 1) * NEUTRAL;
        return Math.max(0.0, Math.min(100.0, NEUTRAL + delta));
    }

    /**
     * 完成度：看完 / 收藏。
     *
     * <p>没有任何未看信号（全是「看过」）时给中性 50，而不是假性 100——数据源天然全「看过」时，
     * 100 分说明不了任何事。otaku 的 {@code watching} 本身就是「没看完」，直接计入未看。
     */
    static double completion(List<DimWork> works) {
        // 抛弃的作品不进分母（#496）：它是「我不看了」，不是「还没看完」。
        // 计入分母会把完播率越拉越低，读起来像「你囤了很多」，其实那些是被否掉的。
        List<DimWork> counted = works.stream()
                .filter(w -> !"dropped".equals(w.status()))
                .toList();
        if (counted.isEmpty()) {
            return NEUTRAL;
        }
        long watched = counted.stream().filter(w -> "watched".equals(w.status())).count();
        long unseen = counted.stream()
                .filter(w -> w.status() == null
                        || "want".equals(w.status())
                        || "watching".equals(w.status()))
                .count();
        if (unseen == 0) {
            return NEUTRAL;
        }
        return round((double) watched / counted.size() * 100);
    }

    // ---------------------------------------------------------------- 内部工具

    /** 每部作品命中的题材去重后计数（一部作品同一个题材只算一次）。 */
    static Map<String, Integer> genreCounts(List<DimWork> works, Set<String> genreTags) {
        if (genreTags == null || genreTags.isEmpty()) {
            return Map.of();
        }
        Map<String, Integer> counts = new LinkedHashMap<>();
        for (DimWork work : works) {
            work.tags().stream()
                    .filter(genreTags::contains)
                    .distinct()
                    .forEach(tag -> counts.merge(tag, 1, Integer::sum));
        }
        return counts;
    }

    /** 单部作品的热度百分位；无热度数据返回 null（不参与平均，也不当 0 混进去）。 */
    static Double heatPercentile(DimWork work) {
        Long count = work.ratingCount();
        if (count == null || count <= 0) {
            return null;
        }
        double log = Math.log10(Math.max(1.0, count));
        double[][] a = POP_ANCHORS;
        if (log <= a[0][0]) {
            return a[0][1];
        }
        for (int i = 0; i < a.length - 1; i++) {
            double x0 = a[i][0];
            double x1 = a[i + 1][0];
            if (log <= x1) {
                double span = x1 - x0;
                return span <= 0 ? a[i][1] : a[i][1] + (log - x0) / span * (a[i + 1][1] - a[i][1]);
            }
        }
        return a[a.length - 1][1];
    }

    private static List<Double> percentiles(List<DimWork> works) {
        List<Double> values = new ArrayList<>();
        for (DimWork work : works) {
            Double p = heatPercentile(work);
            if (p != null) {
                values.add(p);
            }
        }
        return values;
    }

    private static boolean hits(DimWork work, Set<String> tags) {
        return work.tags().stream().anyMatch(tags::contains);
    }

    private static double mean(List<Double> values) {
        return values.stream().mapToDouble(Double::doubleValue).average().orElse(NEUTRAL);
    }

    /** 总体标准差（除以 n，不是 n-1）：与网站口径一致，这里是描述分布不是估计总体。 */
    private static double stdDev(List<Double> values) {
        double m = mean(values);
        double variance = values.stream().mapToDouble(v -> (v - m) * (v - m)).average().orElse(0.0);
        return Math.sqrt(variance);
    }

    /** 保留一位小数并夹在 0–100：雷达图只吃这个范围，越界要在这里拦住。 */
    static double round(double value) {
        double clamped = Math.max(0.0, Math.min(100.0, value));
        return Math.round(clamped * 10.0) / 10.0;
    }
}

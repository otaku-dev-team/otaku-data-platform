package com.otaku.persona;

import com.otaku.persona.dto.PersonaDtos;
import com.otaku.user.UserRecord;
import org.springframework.stereotype.Service;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.Clock;
import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;

/**
 * 阿宅画像聚合（#401 B1）。
 *
 * <h2>信号权重（纯规则、可解释）</h2>
 *
 * | 行为 | 权重 | 理由 |
 * |---|---|---|
 * | 浏览 | `1.0 + 0.25 × (次数 - 1)`，封顶 `2.0` | 看过一次是弱信号；反复看是强兴趣，但别让刷页把画像刷歪 |
 * | 收藏-想看 | `2.0` | 主动表达意图，但还没消费 |
 * | 收藏-在看 | `3.0` | 正在消费 |
 * | 收藏-看过 | `4.0` | 已消费，最强 |
 * | 点评 7–10 分 | `+3.0`（有正文再 `+0.5`） | 高分是「喜欢」的直接证据 |
 * | 点评 5–6 分 | `+1.5`（有正文再 `+0.5`） | 中性偏正面 |
 * | 点评 1–4 分 | `-1.5` | **负反馈**：低分作品的标签说明「不喜欢」，不能当 0 分处理 |
 *
 * <h2>评分信号的两个来源（#495）</h2>
 *
 * 评分倾向不只看自己写的点评：用户在 Bangumi / B 站导入的收藏自带评分，那同样是「我觉得它几分」。
 * 口径是**自己的分优先，没有才回落到作品在来源站的均分**（`work.rating_value`，按 `rating_scale`
 * 归一成 1–10）。认不出量纲（0–5、百分比、五星……）就不猜——宁缺勿错，猜错会把 5 分制的 4 分
 * 当 10 分制的 4 分，整条评分轴都歪掉。
 *
 * <p>评分按 `work_id` 去重：同一部作品可能同时出现在浏览 / 收藏 / 点评三路里，不去重会把它
 * 算三遍，均值变成「我自己点了几次」的函数。
 *
 * <p>标签按「作品标签数」均摊（`weight / tagCount`）：一部作品挂 20 个标签时，
 * 每个标签只分到 1/20 的证据，避免「标签多的作品」主导画像。
 *
 * <h2>为什么实时算、不落画像表</h2>
 *
 * 首版用户行为行数少（上限 = 看过的作品数 × 3 路），一次 UNION ALL 加内存聚合就够。
 * 落表要引入「什么时候重算」的一致性问题和一张新的迁移表，收益还看不见。
 * 等真出现「画像接口 P95 拖垮」（目前不可能），再按 #413 的统一服务一起做缓存。
 */
@Service
public class PersonaService {

    /** 行为行上限：正常用户远达不到；只防「脚本刷浏览」把接口拖死。 */
    static final int MAX_SIGNALS = 2000;
    /** 「近期活跃」的时间窗与条数。 */
    static final int RECENT_DAYS = 30;
    static final int RECENT_LIMIT = 20;

    /** 老番分界：2010 年及以前算老番，与网站 {@code early_share} 同口径。 */
    static final int EARLY_YEAR = 2010;

    static final double VIEW_BASE = 1.0;
    static final double VIEW_STEP = 0.25;
    static final double VIEW_CAP = 2.0;
    static final double COLLECTION_WANT = 2.0;
    static final double COLLECTION_WATCHING = 3.0;
    static final double COLLECTION_WATCHED = 4.0;
    /** 收藏了但没设状态（契约允许 status 为空）：按「想看」算，不猜。 */
    static final double COLLECTION_UNSET = 2.0;
    /**
     * 抛弃（#496）：**负权重**，与点评 1–4 分的 {@link #REVIEW_LOW} 同量级。
     *
     * <p>为什么必须为负：把「明确不喜欢」当 0 或当「想看」（+2.0）都会让口味向量
     * 朝反方向长——用户越讨厌某个题材，系统越以为他喜欢。量级取 -2.0 而不是 -4.0：
     * 一次「抛弃」有冲动成分（看了两集不合口味），不应压过一部打完 9 分的作品。
     */
    static final double COLLECTION_DROPPED = -2.0;
    static final double REVIEW_HIGH = 3.0;
    static final double REVIEW_MID = 1.5;
    static final double REVIEW_LOW = -1.5;
    static final double REVIEW_BODY_BONUS = 0.5;
    static final int REVIEW_HIGH_FROM = 7;
    static final int REVIEW_MID_FROM = 5;
    static final int RATING_BUCKETS = 10;

    private final PersonaRepository repository;
    private final Clock clock;
    /** 题材白名单：决定哪些标签算「题材」（九维里的 tag_focus / exploration 靠它）。 */
    private final java.util.Set<String> genreTags;

    /**
     * 生产用：时钟就是系统 UTC 时钟。标 {@code @Autowired} 是因为下面还有给测试的构造器。
     *
     * <p>{@code app.persona.genre-tags} 是**逗号分隔的题材词表**，默认为空。
     * 为什么做成配置而不是常量：仓库里没有任何「题材分类」的权威来源——
     * `work.tags` 是 JSON 数组（题材、公司、角色混在一起），数据集的 `tags` 表虽然建了
     * `kind` 列，映射只导了 `name`。硬编码一份名单等于替来源定义分类（#467 已否过一次）。
     * 空表时 {@link PersonaDimensions} 的 tag_focus / exploration 返回中性 50，
     * 其余七维照常——这是「没有分类就不假装有」。
     */
    @org.springframework.beans.factory.annotation.Autowired
    public PersonaService(PersonaRepository repository,
                          @org.springframework.beans.factory.annotation.Value(
                                  "${app.persona.genre-tags:}") String genreTagsCsv) {
        this(repository, Clock.systemUTC(), parseGenreTags(genreTagsCsv));
    }

    PersonaService(PersonaRepository repository, Clock clock) {
        this(repository, clock, java.util.Set.of());
    }

    PersonaService(PersonaRepository repository, Clock clock, java.util.Set<String> genreTags) {
        this.repository = repository;
        this.clock = clock;
        this.genreTags = genreTags;
    }

    private static java.util.Set<String> parseGenreTags(String raw) {
        if (raw == null || raw.isBlank()) {
            return java.util.Set.of();
        }
        java.util.Set<String> tags = new LinkedHashSet<>();
        for (String part : raw.split(",")) {
            String tag = part.trim();
            if (!tag.isEmpty()) {
                tags.add(tag);
            }
        }
        return tags;
    }

    public PersonaDtos.PersonaProfile build(UserRecord user) {
        List<PersonaRepository.SignalRow> signals =
                repository.findSignals(user.id(), MAX_SIGNALS);

        Map<String, Double> rawTypes = new LinkedHashMap<>();
        Map<String, Double> rawTags = new LinkedHashMap<>();
        // 评分按 work_id 去重：同一作品可能同时出现在浏览 / 收藏 / 点评三路里，
        // 不去重会把它算三遍，均值变成「我自己点了几次」的函数。
        Map<String, Integer> ratingsByWork = new LinkedHashMap<>();
        // 已经用「我自己的点评分」占过的作品：源站均分不再覆盖它。
        java.util.Set<String> ownRatedWorks = new java.util.HashSet<>();
        // 九维的输入按**作品**去重（同一作品可能同时出现在浏览/收藏/点评三路）。
        Map<String, DimAgg> dimWorks = new LinkedHashMap<>();
        // 被抛弃的作品不进九维（#496）：维度测的是「口味版图」，把明确拒绝的东西画进去
        // 等于说「你爱看你不爱看的东西」。标签权重仍然记负分，两条路互不影响。
        java.util.Set<String> droppedWorks = new java.util.HashSet<>();
        LinkedHashSet<String> recentActive = new LinkedHashSet<>();
        LocalDateTime recentCutoff = LocalDateTime.now(clock).minusDays(RECENT_DAYS);

        for (PersonaRepository.SignalRow row : signals) {
            double weight = weightOf(row);
            if (weight == 0.0) {
                continue;
            }
            rawTypes.merge(row.workType(), weight, Double::sum);

            List<String> tags = row.tags();
            if (tags != null && !tags.isEmpty()) {
                double perTag = weight / tags.size();
                for (String tag : tags) {
                    if (tag != null && !tag.isBlank()) {
                        rawTags.merge(tag, perTag, Double::sum);
                    }
                }
            }

            boolean dropped = "collection".equals(row.kind())
                    && "dropped".equals(row.collectionStatus());
            if (dropped) {
                // 只记「这部被拒过」，不建 DimWork；若别处（浏览）已建，最后统一剔除。
                droppedWorks.add(row.workId());
            } else {
                DimAgg agg = dimWorks.computeIfAbsent(row.workId(),
                        id -> new DimAgg(row.workType(), row.tags(),
                                row.releaseYear(), row.ratingCount()));
                if (row.collectionStatus() != null) {
                    // 只有收藏行带状态；浏览/点评行为 null，不能被它们覆盖成 null。
                    agg.status = row.collectionStatus();
                }
            }

            // 自己打的分优先于源站均分：先到的那条可能是浏览行（带的是站内均分），
            // 不能让它在时间序上抢在用户自己的点评前面。ownRatedWorks 记住「这部作品
            // 已经有我自己的分」，后续的回落值一律不覆盖。
            Integer own = row.rating();
            if (own != null) {
                ownRatedWorks.add(row.workId());
                ratingsByWork.put(row.workId(), own);
            } else if (!ownRatedWorks.contains(row.workId())) {
                Integer fallback = normalizeRating(row.workRating(), row.workRatingScale());
                if (fallback != null) {
                    ratingsByWork.putIfAbsent(row.workId(), fallback);
                }
            }

            if (recentActive.size() < RECENT_LIMIT
                    && row.happenedAt() != null
                    && !row.happenedAt().isBefore(recentCutoff)) {
                recentActive.add(row.workId());
            }
        }

        List<PersonaDimensions.DimWork> dimInputs = new ArrayList<>(dimWorks.size());
        dimWorks.forEach((workId, agg) -> {
            if (droppedWorks.contains(workId)) {
                return;
            }
            dimInputs.add(new PersonaDimensions.DimWork(
                    agg.tags, agg.year, ratingsByWork.get(workId),
                    // work.rating_count 是 INT；DimWork 要 Long（分位锚点按 log10 算，用不上精度）
                    agg.ratingCount == null ? null : agg.ratingCount.longValue(),
                    agg.status));
        });
        Map<String, Double> dimensions = PersonaDimensions.compute(
                dimInputs, genreTags, LocalDateTime.now(clock).getYear());

        // 称号与标签解读要的是「作品数」而不是「行为条数」：同一部作品出现在浏览 / 收藏 /
        // 点评三路里只算一部，否则刷几次页面就把题材占比刷歪。
        //
        // 被抛弃的作品**不算进题材/身份占比**（与九维同一口径：拒绝的东西不是口味），
        // 但要单独计数——「三集弃之神」这类称号判的就是它（#540 之后才有数据）。
        int want = 0;
        int seen = 0;
        int countedWorks = 0;
        Map<String, Integer> typeCounts = new LinkedHashMap<>();
        Map<String, Integer> tagCounts = new LinkedHashMap<>();
        List<Integer> years = new ArrayList<>();
        for (Map.Entry<String, DimAgg> entry : dimWorks.entrySet()) {
            if (droppedWorks.contains(entry.getKey())) {
                continue;
            }
            DimAgg agg = entry.getValue();
            countedWorks++;
            if ("want".equals(agg.status)) {
                want++;
            } else if ("watched".equals(agg.status)) {
                seen++;
            }
            if (agg.type != null && !agg.type.isBlank()) {
                typeCounts.merge(agg.type, 1, Integer::sum);
            }
            for (String tag : agg.tags) {
                if (tag != null && !tag.isBlank()) {
                    tagCounts.merge(tag, 1, Integer::sum);
                }
            }
            if (agg.year != null) {
                years.add(agg.year);
            }
        }

        PersonaTitle.Input titleInput = new PersonaTitle.Input(
                dimensions,
                countedWorks,
                want,
                seen,
                // 抛弃数（#540 之后才有真实数据）：原版留的 0 常量在这里接上。
                droppedWorks.size(),
                PersonaTitle.cluster(tagCounts),
                PersonaTitle.identity(shares(typeCounts, countedWorks)),
                tagCounts,
                earlyShare(years),
                // 稀有度占比没有站内校准样本，null 表示「未标定」——不拿别的数凑。
                null);
        PersonaTitle.Title title = PersonaTitle.assign(titleInput);
        PersonaTitle.Rarity rarity = PersonaTitle.rarity(title.code());

        return new PersonaDtos.PersonaProfile(
                normalize(rawTypes),
                normalize(rawTags),
                tendency(new ArrayList<>(ratingsByWork.values())),
                List.copyOf(recentActive),
                signals.size(),
                dimensions,
                PersonaTitle.personaTags(titleInput),
                PersonaTitle.traitBlurbs(titleInput),
                title.title(),
                title.code(),
                title.note(),
                PersonaTitle.finalQuip(Long.toString(user.id())),
                new PersonaDtos.Rarity(rarity.tier(), rarity.label(), rarity.note(), rarity.share()),
                OffsetDateTime.now(clock));
    }

    /** 媒介占比（0–100）：主身份按「单一媒介过半」判定，所以给百分比而不是归一化权重。 */
    static Map<String, Double> shares(Map<String, Integer> counts, int total) {
        if (counts.isEmpty() || total <= 0) {
            return Map.of();
        }
        Map<String, Double> out = new LinkedHashMap<>();
        counts.forEach((key, count) -> out.put(key, round3(count * 100.0 / total)));
        return out;
    }

    /**
     * 老番占比：{@link #EARLY_YEAR} 年及以前的作品占「有年份」作品的比例。
     *
     * <p>不看最早那一部——库里必然躺着老番，随手补一部就会被判成老资历
     * （网站侧实测 18 个账号里 9 个中招，所以才改成占比）。
     */
    static double earlyShare(List<Integer> years) {
        if (years == null || years.isEmpty()) {
            return 0.0;
        }
        long early = years.stream().filter(year -> year <= EARLY_YEAR).count();
        return round3(early * 100.0 / years.size());
    }

    /**
     * 把「作品均分 + 量纲」归一成 1–10 的整数分；**认不出量纲就不猜**。
     *
     * <p>量纲为空按 {@code 0-10} 处理：那是 `work.rating_scale` 列的既有含义，
     * 也是当前全部数据（94,443 行）的实际值，不是假设。
     * 明确写着别的量纲（`0-5` / `percentage` / 五星）一律返回 null——猜错会把 5 分制的
     * 4 分当成 10 分制的 4 分，整条评分轴都歪，而且不会报错。
     *
     * <p>四舍五入到整数：`rating_tendency.dist` 是 10 个整数桶，9.06 归到 9 分桶；
     * 越界裁剪到 1–10（0 分按 1 分记——作品的 `rating_value` 非空就代表「有评分」，
     * 「0 分」在评分语义里几乎都等于「没打分」）。
     */
    static Integer normalizeRating(BigDecimal value, String scale) {
        if (value == null) {
            return null;
        }
        String normalized = scale == null ? "" : scale.trim();
        if (!normalized.isEmpty() && !"0-10".equals(normalized) && !"1-10".equals(normalized)) {
            return null;
        }
        double raw = value.doubleValue();
        if (Double.isNaN(raw) || Double.isInfinite(raw)) {
            return null;
        }
        long rounded = Math.round(raw);
        return (int) Math.max(1, Math.min(10, rounded));
    }

    /** 单条行为的权重；未知 kind 记 0（不认识的信号不参与画像，也不报错）。 */
    static double weightOf(PersonaRepository.SignalRow row) {
        return switch (row.kind() == null ? "" : row.kind()) {
            case "view" -> Math.min(VIEW_CAP, VIEW_BASE + VIEW_STEP * Math.max(0, row.viewCount() - 1));
            case "collection" -> collectionWeight(row.collectionStatus());
            case "review" -> reviewWeight(row.rating());
            default -> 0.0;
        };
    }

    private static double collectionWeight(String status) {
        if (status == null || status.isBlank()) {
            return COLLECTION_UNSET;
        }
        return switch (status) {
            case "want" -> COLLECTION_WANT;
            case "watching" -> COLLECTION_WATCHING;
            case "watched" -> COLLECTION_WATCHED;
            case "dropped" -> COLLECTION_DROPPED;
            default -> COLLECTION_UNSET;
        };
    }

    private static double reviewWeight(Integer rating) {
        if (rating == null) {
            // 只写正文不打分：仍是「愿意花时间表达」的正面信号，按中性偏正处理。
            return REVIEW_BODY_BONUS;
        }
        if (rating >= REVIEW_HIGH_FROM) {
            return REVIEW_HIGH;
        }
        if (rating >= REVIEW_MID_FROM) {
            return REVIEW_MID;
        }
        return REVIEW_LOW;
    }

    /**
     * 归一化：除以该维度的绝对值最大者，保留 3 位小数，按权重降序。
     *
     * <p>全 0 / 空 → 空 map（不返回一堆 0.0，客户端据此显示「还没有足够数据」）。
     */
    static Map<String, Double> normalize(Map<String, Double> raw) {
        if (raw.isEmpty()) {
            return Map.of();
        }
        double max = raw.values().stream().mapToDouble(Math::abs).max().orElse(0.0);
        if (max <= 0.0) {
            return Map.of();
        }
        Map<String, Double> sorted = new LinkedHashMap<>();
        raw.entrySet().stream()
                .sorted(Map.Entry.<String, Double>comparingByValue(Comparator.reverseOrder()))
                .forEach(e -> sorted.put(e.getKey(), round3(e.getValue() / max)));
        return sorted;
    }

    private static double round3(double value) {
        return BigDecimal.valueOf(value).setScale(3, RoundingMode.HALF_UP).doubleValue();
    }

    /** 评分倾向：均值一位小数；`dist` 恒 10 桶（下标 0 = 1 分）。 */
    static PersonaDtos.RatingTendency tendency(List<Integer> ratings) {
        List<Integer> dist = new ArrayList<>(RATING_BUCKETS);
        for (int i = 0; i < RATING_BUCKETS; i++) {
            dist.add(0);
        }
        if (ratings.isEmpty()) {
            return new PersonaDtos.RatingTendency(null, 0, dist);
        }
        long sum = 0;
        for (Integer rating : ratings) {
            if (rating == null) {
                continue;
            }
            sum += rating;
            int bucket = Math.min(RATING_BUCKETS - 1, Math.max(0, rating - 1));
            dist.set(bucket, dist.get(bucket) + 1);
        }
        BigDecimal mean = BigDecimal.valueOf(sum)
                .divide(BigDecimal.valueOf(ratings.size()), 1, RoundingMode.HALF_UP);
        return new PersonaDtos.RatingTendency(mean, ratings.size(), dist);
    }

    /**
     * 九维输入的作品级聚合：同一作品的三路信号要合并成一条，否则「今年看了 5 遍」会被算成 5 部。
     * 只有 {@code status} 会在多行之间被补全（收藏行有、浏览/点评行没有）。
     */
    private static final class DimAgg {
        private final String type;
        private final List<String> tags;
        private final Integer year;
        private final Integer ratingCount;
        private String status;

        private DimAgg(String type, List<String> tags, Integer year, Integer ratingCount) {
            this.type = type;
            this.tags = tags == null ? List.of() : tags;
            this.year = year;
            this.ratingCount = ratingCount;
        }
    }

    /** 暴露给测试：把「现在」定住，避免 30 天窗口随真实时间漂移。 */
    static Clock clockAt(String isoInstant) {
        return Clock.fixed(java.time.Instant.parse(isoInstant), ZoneOffset.UTC);
    }
}

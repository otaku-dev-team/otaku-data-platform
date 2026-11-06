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

    static final double VIEW_BASE = 1.0;
    static final double VIEW_STEP = 0.25;
    static final double VIEW_CAP = 2.0;
    static final double COLLECTION_WANT = 2.0;
    static final double COLLECTION_WATCHING = 3.0;
    static final double COLLECTION_WATCHED = 4.0;
    /** 收藏了但没设状态（契约允许 status 为空）：按「想看」算，不猜。 */
    static final double COLLECTION_UNSET = 2.0;
    static final double REVIEW_HIGH = 3.0;
    static final double REVIEW_MID = 1.5;
    static final double REVIEW_LOW = -1.5;
    static final double REVIEW_BODY_BONUS = 0.5;
    static final int REVIEW_HIGH_FROM = 7;
    static final int REVIEW_MID_FROM = 5;
    static final int RATING_BUCKETS = 10;

    private final PersonaRepository repository;
    private final Clock clock;

    /** 生产用：时钟就是系统 UTC 时钟。标 {@code @Autowired} 是因为下面还有一个给测试的构造器。 */
    @org.springframework.beans.factory.annotation.Autowired
    public PersonaService(PersonaRepository repository) {
        this(repository, Clock.systemUTC());
    }

    PersonaService(PersonaRepository repository, Clock clock) {
        this.repository = repository;
        this.clock = clock;
    }

    public PersonaDtos.PersonaProfile build(UserRecord user) {
        List<PersonaRepository.SignalRow> signals =
                repository.findSignals(user.id(), MAX_SIGNALS);

        Map<String, Double> rawTypes = new LinkedHashMap<>();
        Map<String, Double> rawTags = new LinkedHashMap<>();
        List<Integer> ratings = new ArrayList<>();
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

            if (row.rating() != null) {
                ratings.add(row.rating());
            }

            if (recentActive.size() < RECENT_LIMIT
                    && row.happenedAt() != null
                    && !row.happenedAt().isBefore(recentCutoff)) {
                recentActive.add(row.workId());
            }
        }

        return new PersonaDtos.PersonaProfile(
                normalize(rawTypes),
                normalize(rawTags),
                tendency(ratings),
                List.copyOf(recentActive),
                signals.size(),
                OffsetDateTime.now(clock));
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

    /** 暴露给测试：把「现在」定住，避免 30 天窗口随真实时间漂移。 */
    static Clock clockAt(String isoInstant) {
        return Clock.fixed(java.time.Instant.parse(isoInstant), ZoneOffset.UTC);
    }
}

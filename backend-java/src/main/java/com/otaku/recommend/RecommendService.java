package com.otaku.recommend;

import com.otaku.persona.PersonaService;
import com.otaku.persona.dto.PersonaDtos;
import com.otaku.recommend.dto.RecommendDtos;
import com.otaku.user.UserRecord;
import com.otaku.work.WorkRecord;
import com.otaku.work.WorkRepository;
import com.otaku.work.WorkService;
import com.otaku.work.WorkSummaryMapper;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.Clock;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * 规则推荐引擎（#402 B3 + B5）。
 *
 * <h2>打分（纯规则、可解释）</h2>
 *
 * `score = Σ(命中标签的画像权重) + 类型权重 × 1.0 + 评分质量 × 0.3`
 *
 * - **标签分**直接取画像的归一化权重（-1–1），命中多个标签就累加；负权重也照加——
 *   用户明确不喜欢的标签不该因为「其他标签还不错」被推荐上来；
 * - **类型分**同理，权重来自画像的 `type_weights`；
 * - **评分质量**只对 `rating_count >= 50`（或票数未知）的作品生效，与列表页
 *   `sort=rating` 的 50 阈值同一常量，避免「3 个人打 10 分」的作品被推上来；
 * - 同分按作品评分降序，再按数据库顺序（已经按标签内评分降序取过）。
 *
 * <h2>召回与排除</h2>
 *
 * 候选来自画像里权重最高的 {@value #TOP_TAGS} 个**正标签**，每个标签取评分最高的
 * {@value #PER_TAG_CANDIDATES} 部（走 `work_tag` 索引，不扫全表）。
 * 已浏览 / 已收藏的作品**全量排除**——画像的 `recent_active` 只有最近 30 天 20 个，
 * 拿它排除会让用户看到半年前看完的片子。
 *
 * <h2>冷启动</h2>
 *
 * 画像为空（新用户、或生产上行为数据还没积累）时返回全站高分榜，`cold_start: true`、
 * 每项的 `reasons` 为空。**不做「随机」也不返回空列表**：空列表对新用户是最差的第一屏。
 */
@Service
public class RecommendService {

    static final int DEFAULT_LIMIT = 20;
    static final int MAX_LIMIT = 50;
    /** 候选标签数：再多会召回大量弱相关作品，打分也救不回来。 */
    static final int TOP_TAGS = 8;
    /** 每个标签取多少部候选（标签内按评分降序）。 */
    static final int PER_TAG_CANDIDATES = 200;
    /** 类型权重系数：与标签分同量级，但不压过「多个标签同时命中」。 */
    static final double TYPE_FACTOR = 1.0;
    /** 评分质量系数：10 分制 × 0.3 = 最多 3 分，是排序的次要因素。 */
    static final double QUALITY_FACTOR = 0.3;
    static final int MAX_REASONS = 3;

    private final PersonaService personaService;
    private final WorkRepository workRepository;
    private final RecommendRepository recommendRepository;
    private final WorkSummaryMapper summaryMapper;
    private final Clock clock;

    @Autowired
    public RecommendService(PersonaService personaService, WorkRepository workRepository,
                            RecommendRepository recommendRepository, WorkSummaryMapper summaryMapper) {
        this(personaService, workRepository, recommendRepository, summaryMapper, Clock.systemUTC());
    }

    RecommendService(PersonaService personaService, WorkRepository workRepository,
                     RecommendRepository recommendRepository, WorkSummaryMapper summaryMapper,
                     Clock clock) {
        this.personaService = personaService;
        this.workRepository = workRepository;
        this.recommendRepository = recommendRepository;
        this.summaryMapper = summaryMapper;
        this.clock = clock;
    }

    public RecommendDtos.RecommendationPage recommend(UserRecord user, Integer rawLimit) {
        int limit = clampLimit(rawLimit);
        PersonaDtos.PersonaProfile profile = personaService.build(user);

        List<Map.Entry<String, Double>> positiveTags = profile.tagWeights().entrySet().stream()
                .filter(e -> e.getValue() != null && e.getValue() > 0)
                .sorted(Map.Entry.<String, Double>comparingByValue(Comparator.reverseOrder()))
                .limit(TOP_TAGS)
                .toList();

        if (positiveTags.isEmpty()) {
            return coldStart(limit);
        }

        Map<String, WorkRecord> candidates = new LinkedHashMap<>();
        for (Map.Entry<String, Double> tag : positiveTags) {
            for (WorkRecord work : workRepository.findVisibleByTag(tag.getKey(), PER_TAG_CANDIDATES)) {
                candidates.putIfAbsent(work.workId(), work);
            }
        }

        Set<String> touched = recommendRepository.touchedWorkIds(user.id());
        List<Scored> scored = new ArrayList<>();
        for (WorkRecord work : candidates.values()) {
            if (touched.contains(work.workId())) {
                continue;
            }
            Scored result = score(work, profile);
            if (result.score() > 0) {
                scored.add(result);
            }
        }
        scored.sort(Comparator.comparingDouble(Scored::score).reversed()
                .thenComparing(s -> ratingOf(s.work()), Comparator.reverseOrder()));

        List<Scored> top = scored.size() > limit ? scored.subList(0, limit) : scored;
        double max = top.isEmpty() ? 0.0 : top.get(0).score();
        List<RecommendDtos.Recommendation> items = top.stream()
                .map(s -> new RecommendDtos.Recommendation(
                        summaryMapper.toSummary(s.work()),
                        max <= 0 ? 0.0 : round3(s.score() / max),
                        s.reasons()))
                .toList();
        return new RecommendDtos.RecommendationPage(items, false, OffsetDateTime.now(clock));
    }

    /** 冷启动：全站高分榜。`score` 恒 0——诚实表示「没有个性化成分」，顺序由热门排序决定。 */
    private RecommendDtos.RecommendationPage coldStart(int limit) {
        List<RecommendDtos.Recommendation> items = workRepository.findPopular(limit).stream()
                .map(w -> new RecommendDtos.Recommendation(summaryMapper.toSummary(w), 0.0, List.of()))
                .toList();
        return new RecommendDtos.RecommendationPage(items, true, OffsetDateTime.now(clock));
    }

    private Scored score(WorkRecord work, PersonaDtos.PersonaProfile profile) {
        double score = 0.0;
        List<RecommendDtos.RecommendationReason> reasons = new ArrayList<>();

        List<String> tags = summaryMapper.tags(work.tagsJson());
        if (tags != null) {
            for (String tag : tags) {
                Double weight = profile.tagWeights().get(tag);
                if (weight == null || weight == 0.0) {
                    continue;
                }
                score += weight;
                if (weight > 0) {
                    reasons.add(new RecommendDtos.RecommendationReason("tag", tag, round3(weight)));
                }
            }
        }

        Double typeWeight = profile.typeWeights().get(work.workType());
        if (typeWeight != null && typeWeight != 0.0) {
            score += typeWeight * TYPE_FACTOR;
            if (typeWeight > 0) {
                reasons.add(new RecommendDtos.RecommendationReason(
                        "type", work.workType(), round3(typeWeight)));
            }
        }

        if (work.ratingValue() != null && trustedRating(work)) {
            score += work.ratingValue().doubleValue() * QUALITY_FACTOR;
        }

        // 命中项按权重降序，只留前 3 条——「因为机战、科幻、anime」比列 12 个标签有用。
        reasons.sort(Comparator.comparingDouble(RecommendDtos.RecommendationReason::weight).reversed());
        List<RecommendDtos.RecommendationReason> top = reasons.size() > MAX_REASONS
                ? reasons.subList(0, MAX_REASONS)
                : reasons;
        return new Scored(work, score, List.copyOf(top));
    }

    /** 票数口径与展示一致：未知（null）按可信，低于 50 视为不可信。 */
    private static boolean trustedRating(WorkRecord work) {
        return work.ratingCount() == null || work.ratingCount() >= WorkService.MIN_RATING_COUNT;
    }

    private static double ratingOf(WorkRecord work) {
        BigDecimal rating = work.ratingValue();
        return rating == null ? 0.0 : rating.doubleValue();
    }

    static int clampLimit(Integer rawLimit) {
        if (rawLimit == null || rawLimit < 1) {
            return DEFAULT_LIMIT;
        }
        return Math.min(rawLimit, MAX_LIMIT);
    }

    private static double round3(double value) {
        return BigDecimal.valueOf(value).setScale(3, RoundingMode.HALF_UP).doubleValue();
    }

    private record Scored(WorkRecord work, double score,
                          List<RecommendDtos.RecommendationReason> reasons) {
    }
}

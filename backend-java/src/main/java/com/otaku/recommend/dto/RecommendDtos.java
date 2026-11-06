package com.otaku.recommend.dto;

import com.otaku.work.dto.WorkSummaryDto;

import java.time.OffsetDateTime;
import java.util.List;

/**
 * 个性化推荐的对外形状（#402 / #376）。
 *
 * <p>`score` 是**本次结果内归一化到 0–1 的相对分**（除以最高分），不是跨请求可比的绝对分——
 * 客户端画「推荐强度条」用它，别拿它做「今天比昨天更推荐」这种比较。
 *
 * <p>`reasons` 的 `weight` 是画像里的归一化权重（-1–1），不是最终得分；`type` 目前只有
 * `tag` / `type` 两种（冷启动时 items 的 reasons 为空、由顶层 `cold_start` 表示）。
 */
public final class RecommendDtos {

    private RecommendDtos() {
    }

    public record RecommendationPage(
            List<Recommendation> items,
            boolean coldStart,
            OffsetDateTime generatedAt
    ) {
    }

    public record Recommendation(
            WorkSummaryDto work,
            double score,
            List<RecommendationReason> reasons
    ) {
    }

    /** 命中项：`type=tag` 时 `value` 是标签名，`type=type` 时是作品类型（anime/comic/…）。 */
    public record RecommendationReason(
            String type,
            String value,
            double weight
    ) {
    }
}

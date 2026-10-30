package com.otaku.ugc.dto;

import java.util.List;

/**
 * 作品评分概览。
 *
 * <p>{@code total} 是已发布的点评条数（含只写文字不打分的）；
 * {@code rated} 是其中打了分的条数；{@code average} 只对打了分的求均值，可为 null。
 *
 * <p>{@code distribution} 是各分数的条数（1–10），没有的分数不出现——
 * 不补 0 是为了让客户端能直接画「有数据的柱子」，而不是先过滤一遍。
 */
public record UgcReviewSummary(
        long total,
        long rated,
        Double average,
        List<Bucket> distribution
) {
    /** 某个分数的条数。 */
    public record Bucket(int rating, int count) {
    }
}

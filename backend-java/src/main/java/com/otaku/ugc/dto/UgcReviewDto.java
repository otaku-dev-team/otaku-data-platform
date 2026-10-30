package com.otaku.ugc.dto;

import java.time.Instant;

/**
 * 一条点评（对外形状）。
 *
 * <p>{@code rating} 与 {@code body} 至少有一个非空：只打分、只写评都行，两样都空不叫点评。
 * {@code rating} 为 null 表示「只写了文字，没打分」——它**不参与均分**，否则会被当成 0 分拉低。
 *
 * <p>{@code author} 对已注销用户显示「已注销用户」（与评论同一口径）。
 */
public record UgcReviewDto(
        String reviewId,
        String workId,
        String author,
        Integer rating,
        String body,
        String status,
        Instant createdAt,
        Instant editedAt
) {
}

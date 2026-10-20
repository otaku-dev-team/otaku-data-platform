package com.otaku.collection;

import java.math.BigDecimal;
import java.time.LocalDateTime;

/**
 * 收藏 + 作品的联表视图，供列表接口一次查完，避免 N+1。
 * 作品字段只取列表需要的几列（不含 summary）。
 */
public record CollectionWorkRow(
        String workId,
        String status,
        LocalDateTime updatedAt,
        String workType,
        String title,
        String coverSourceUrl,
        String tagsJson,
        BigDecimal ratingValue,
        String ratingScale,
        String ratingSource
) {
}

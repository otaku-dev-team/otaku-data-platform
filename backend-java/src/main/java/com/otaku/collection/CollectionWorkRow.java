package com.otaku.collection;

import java.time.LocalDateTime;

/**
 * 收藏 + 作品的联表视图，供列表与单条查询一次查完，避免 N+1。
 * 作品字段只取契约 §4.4 要求的几列（不含 summary / tags / 评分）。
 */
public record CollectionWorkRow(
        String workId,
        String status,
        LocalDateTime createdAt,
        LocalDateTime updatedAt,
        String workType,
        String title,
        String coverSourceUrl
) {
}

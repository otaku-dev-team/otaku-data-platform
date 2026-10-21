package com.otaku.collection.dto;

import java.time.Instant;

/**
 * 收藏列表项，字段与契约 §4.4 一致：
 * 只给列表需要的作品字段（不含 summary、不含 tags/main_rating），另带个人状态与两个时间戳。
 */
public record CollectionItemDto(
        String workId,
        String workType,
        String title,
        String coverUrl,
        String status,
        Instant createdAt,
        Instant updatedAt
) {
}

package com.otaku.collection.dto;

import java.time.Instant;

/**
 * 单条收藏状态，对应契约 §4.5 / §4.6 / §4.7。
 * 未收藏不是错误：collected=false，status 与 updated_at 为 null。
 */
public record CollectionStateDto(
        String workId,
        boolean collected,
        String status,
        Instant createdAt,
        Instant updatedAt
) {
    public static CollectionStateDto notCollected(String workId) {
        return new CollectionStateDto(workId, false, null, null, null);
    }
}

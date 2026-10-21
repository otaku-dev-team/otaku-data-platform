package com.otaku.collection;

import java.time.LocalDateTime;

/** collection 表的一行（不含作品字段）。 */
public record CollectionRecord(
        Long id,
        long userPk,
        String workId,
        String status,
        LocalDateTime createdAt,
        LocalDateTime updatedAt
) {
}

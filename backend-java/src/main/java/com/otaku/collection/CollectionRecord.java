package com.otaku.collection;

import java.time.LocalDateTime;

/** collection 表的一行（不含作品字段）。 */
public record CollectionRecord(
        Long id,
        long userPk,
        String workId,
        String status,
        /**
         * 来源（#506）：{@code user} = 用户操作，{@code quiz} = 冷启动漏斗种子。
         * 种子永远不能覆盖用户操作，规则落在 {@link CollectionRepository#applyWrite} 的 SQL 里。
         */
        String source,
        LocalDateTime createdAt,
        LocalDateTime updatedAt
) {
}

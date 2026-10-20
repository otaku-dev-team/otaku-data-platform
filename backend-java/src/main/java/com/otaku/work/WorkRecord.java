package com.otaku.work;

import java.math.BigDecimal;
import java.time.LocalDateTime;

/**
 * work 表的一行（内部模型，不直接序列化给客户端）。
 *
 * 几个刻意的设计：
 * - tagsJson 保留 SQL NULL 与 "[]" 的区别：NULL = 来源未提供（更新时不覆盖），
 *   "[]" = 明确无标签（可清空），见契约 2.3 与 4.4.3；
 * - coverSourceUrl 是来源站地址，永不出现在响应里；对外地址由 cover_url 重新拼；
 * - 时间统一存 UTC 的 LocalDateTime，出参时转 Instant（带 Z 的 RFC 3339）。
 */
public record WorkRecord(
        Long id,
        String workId,
        String workType,
        String title,
        String summary,
        String coverSourceUrl,
        String coverCacheKey,
        LocalDateTime coverCachedAt,
        String tagsJson,
        BigDecimal ratingValue,
        String ratingScale,
        String ratingSource,
        String source,
        String sourceId,
        LocalDateTime createdAt,
        LocalDateTime updatedAt
) {
}

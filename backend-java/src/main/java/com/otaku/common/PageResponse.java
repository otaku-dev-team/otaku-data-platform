package com.otaku.common;

import java.util.List;

/**
 * 分页响应：{total, page, page_size, total_pages, items}
 * 字段名由 spring.jackson.property-naming-strategy=SNAKE_CASE 统一转换。
 */
public record PageResponse<T>(
        int page,
        int pageSize,
        long total,
        int totalPages,
        List<T> items
) {

    public static <T> PageResponse<T> of(int page, int pageSize, long total, List<T> items) {
        int totalPages = pageSize <= 0 ? 0 : (int) ((total + pageSize - 1) / pageSize);
        return new PageResponse<>(page, pageSize, total, totalPages, items);
    }
}

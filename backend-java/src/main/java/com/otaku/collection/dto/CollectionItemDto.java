package com.otaku.collection.dto;

import com.otaku.work.dto.SourceRatingDto;

import java.time.Instant;
import java.util.List;

/**
 * 收藏列表项：作品摘要（不含 summary）+ 个人状态。
 * 作品字段复用接口③的形态，客户端可以共用同一套卡片渲染。
 */
public record CollectionItemDto(
        String workId,
        String workType,
        String title,
        String coverUrl,
        List<String> tags,
        SourceRatingDto mainRating,
        String status,
        Instant updatedAt
) {
}

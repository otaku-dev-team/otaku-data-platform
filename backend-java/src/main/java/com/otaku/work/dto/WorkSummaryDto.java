package com.otaku.work.dto;

import java.util.List;

/**
 * 列表项：**7 个字段，不含 summary**（契约 2.1 / 6.1）。
 * 简介最长 7225 字，带进列表会把响应撑爆——需要简介请按 work_id 拉详情。
 */
public record WorkSummaryDto(
        String workId,
        String workType,
        String title,
        Integer releaseYear,
        String coverUrl,
        List<String> tags,
        SourceRatingDto mainRating
) {
}

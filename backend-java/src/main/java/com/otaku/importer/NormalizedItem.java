package com.otaku.importer;

/**
 * 校验并规范化后的提交项：只保留真正参与入库的字段，
 * 所有"空"在这里已经统一成 null（空字符串不进入持久层）。
 */
record NormalizedItem(
        String sourceId,
        String workType,
        String title,
        String summary,
        String coverUrl,
        String tagsJson,
        java.math.BigDecimal ratingValue,
        String ratingScale,
        String ratingSource
) {
}

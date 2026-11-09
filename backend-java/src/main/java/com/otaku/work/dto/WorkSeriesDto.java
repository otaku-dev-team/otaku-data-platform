package com.otaku.work.dto;

import java.util.List;

/**
 * 详情页「系列作品」区块（#411 / #557）。
 *
 * <p>为什么不直接返回 {@code List<WorkSummaryDto>}：客户端要把系列名画成区块标题，
 * 而名字只存在于 `series` 表、不在任何一件作品上；让客户端拿第一件作品的标题去猜系列名
 * 是最常见的那种「看起来能用、换个数据就错」的做法（首部作品的标题不等于系列名）。
 *
 * <p>没有系列时返回 {@code seriesKey=null} 且 {@code items=[]}，**不是 404**：
 * 作品存在、只是不属于任何系列，这是正常状态（与 `/related`、`/articles` 同口径）。
 *
 * <p>2026-11-09（#557）起 {@code items} 的每一项是 {@link SeriesItemDto}（作品卡 + 关系标签），
 * 不再是裸的 {@code WorkSummary}。原因是首站系列区每张卡都带「前作 / 续作 / 衍生作 / 同系列」，
 * 而我们的接口只给了 items——客户端要么没有标签可显示，要么只能自己按标题猜。
 */
public record WorkSeriesDto(
        String seriesKey,
        String seriesName,
        List<SeriesItemDto> items
) {
}

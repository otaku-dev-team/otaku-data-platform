package com.otaku.series.dto;

import com.otaku.work.dto.WorkSummaryDto;

import java.util.List;

/**
 * 系列页（#557）：`GET /api/series/{key}`。
 *
 * <p>与详情页的 {@code WorkSeries} 分开两个形状，因为语义不同：
 * 系列页是「一整个系列的目录页」（按评分排、分页、头部要显示总数），
 * 详情页区块是「当前作品在系列里的位置」（按年代排、不分页、带关系标签）。
 * 合成一个形状的结果是两边各背一半用不到的字段。
 *
 * <p>{@code name} 可能为 {@code null}：作品先到、系列行后到是常态
 * （数据集的两张表分开导入）。这时客户端用 key 兜底或隐藏标题，
 * **不要拿 key 当名字**——那是来源站内部 id。
 *
 * <p>{@code total} 是**可见作品总数**，不是 {@code items} 的长度：
 * 首站系列页把截断后的长度当总数，超过 60 部的系列数字就是错的（`creators.html`）。
 * 我们单独给，客户端别再自己数。
 */
public record SeriesPageDto(
        String key,
        String name,
        long total,
        List<WorkSummaryDto> items
) {
}

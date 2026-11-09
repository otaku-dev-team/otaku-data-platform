package com.otaku.home.dto;

import com.otaku.work.dto.WorkSummaryDto;

import java.util.List;

/**
 * 首页 hero 海报位（#561）。
 *
 * <p>为什么是对象而不是裸数组：同一个 {@code /api/home} 下将来还会有别的区块
 * （「最近浏览」「高分」），裸数组的响应一旦要加第二个字段就得整体改形状；
 * 包一层 {@code items} 是零成本的向后兼容余量。参考 {@code RelatedWorks} 的取舍。
 *
 * <p>{@code items} 可能为空数组：当季没有任何「有可解析封面」的动画时，
 * 客户端隐藏 hero，**不要用假数据填充**（首站的做法是留一块空白，那更糟）。
 */
public record HomePosters(List<WorkSummaryDto> items) {
}

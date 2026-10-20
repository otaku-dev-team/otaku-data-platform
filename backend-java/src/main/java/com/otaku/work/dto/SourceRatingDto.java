package com.otaku.work.dto;

import java.math.BigDecimal;

/**
 * 来源评分。整个对象为 null 表示"来源没有评分"，**不是 0 分**，
 * 客户端必须整块不渲染（契约 2.1、6.3）。
 */
public record SourceRatingDto(BigDecimal value, String scale, String source) {
}

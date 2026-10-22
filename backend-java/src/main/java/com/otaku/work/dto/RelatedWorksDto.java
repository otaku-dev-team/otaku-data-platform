package com.otaku.work.dto;

import java.util.List;

/**
 * 详情页「相关内容推荐」。
 *
 * <p>{@code basisTags} 是本次实际用于匹配的标签，客户端据此显示
 * 「同题材：科幻、机战」这类理由；没有标签时为空数组，{@code items} 也为空。
 *
 * <p>为什么不直接返回数组：推荐需要解释，且将来可能加「按共享标签数排序」的得分字段，
 * 留一层对象比改响应形状便宜。
 */
public record RelatedWorksDto(
        List<String> basisTags,
        List<WorkSummaryDto> items
) {
}

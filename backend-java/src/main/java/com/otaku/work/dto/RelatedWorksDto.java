package com.otaku.work.dto;

import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.function.Function;
import java.util.stream.Collector;
import java.util.stream.Collectors;

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

    /**
     * 按标题去重的收集器：同名作品只保留**第一条**。
     *
     * <p>调用方传进来的序列已按「评分降序、id 降序」排好（见
     * {@code WorkRepository.findRelated}），所以第一条就是该标题里最优的那条。
     *
     * <p>键做 trim + 小写归一：多来源并存时同一作品的标题可能有大小写或首尾空白
     * 差异（如 "ABC" 与 "abc "），直接比字符串会漏。值保留原始对象，
     * 展示用的标题不被改写。
     *
     * <p>为什么在 Java 侧去重而不是 SQL {@code GROUP BY title}：那样要再加一层
     * 聚合取每组最优行，SQL 更复杂且与排序逻辑耦合；这里序列本来就要过一遍流，
     * 顺手去重的代价是 O(n)。
     */
    public static Collector<WorkSummaryDto, ?, LinkedHashMap<String, WorkSummaryDto>> dedupeByTitle() {
        return Collectors.toMap(
                RelatedWorksDto::titleKey,
                Function.identity(),
                (existing, replacement) -> existing,
                LinkedHashMap::new);
    }

    /** 去重后的条目，保持输入顺序（即评分优先）。 */
    public static List<WorkSummaryDto> dedupe(Collection<WorkSummaryDto> items) {
        return items.stream()
                .collect(dedupeByTitle())
                .values()
                .stream()
                .toList();
    }

    private static String titleKey(WorkSummaryDto dto) {
        String title = dto.title();
        return title == null ? "" : title.trim().toLowerCase(Locale.ROOT);
    }
}

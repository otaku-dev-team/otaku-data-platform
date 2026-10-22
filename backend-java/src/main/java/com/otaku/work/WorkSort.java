package com.otaku.work;

import com.otaku.common.ApiException;

/**
 * 列表排序方式。
 *
 * <p>为什么要枚举而不是直接拼 SQL：{@code sort} 是外部可控字符串，拼进 ORDER BY 就是注入面。
 * 这里把「参数值 → 排序子句」写死成常量，调用方只能选中其中之一，非法值直接 400。
 *
 * <p>为什么都带 {@code id} 作次级键：分页要稳定，必须有一个唯一键兜底；只按
 * {@code rating_value} 排，同分记录的顺序在两次查询间可能不同，翻页会重复或漏。
 * 次级键统一用 DESC，与主键 DESC 组合后正好可以走「反向索引扫描」，
 * 不必额外 filesort（实测 55.6 万条下 366ms → 0.4ms）。
 *
 * <p>NULL 的处理：MySQL 升序时 NULL 在前，因此 DESC 排序会把无评分 / 无年份的作品
 * 排在末尾——这正是想要的（没数据的沉底，而不是混在中间）。
 */
public enum WorkSort {

    /** 默认：按物理主键升序，保持第一阶段以来的行为不变。 */
    ID("id ASC"),

    /** 评分从高到低；无评分的排最后。需要索引 idx_work_rating。 */
    RATING("rating_value DESC, id DESC"),

    /** 年份从新到旧；无年份的排最后。需要索引 idx_work_year。 */
    YEAR("release_year DESC, id DESC");

    private final String orderBy;

    WorkSort(String orderBy) {
        this.orderBy = orderBy;
    }

    /** 只允许拼进 ORDER BY 的固定片段，不含任何外部输入。 */
    public String orderBy() {
        return orderBy;
    }

    /**
     * 带表别名的版本（两段式查询的外层用，避免 JOIN 后列名歧义）。
     * 仍然只来自枚举常量，不做任何字符串解析。
     */
    public String orderBy(String alias) {
        if (alias == null || alias.isEmpty()) {
            return orderBy;
        }
        StringBuilder sb = new StringBuilder();
        for (String part : orderBy.split(",")) {
            String trimmed = part.trim();
            int space = trimmed.indexOf(' ');
            String column = space < 0 ? trimmed : trimmed.substring(0, space);
            String direction = space < 0 ? "" : trimmed.substring(space);
            sb.append(alias).append('.').append(column).append(direction).append(", ");
        }
        sb.setLength(sb.length() - 2);
        return sb.toString();
    }

    /**
     * 解析外部参数。省略 / 空串走默认，非法值按契约 6.1 报 400（与「查不到结果」区分开）。
     */
    public static WorkSort parse(String raw) {
        if (raw == null || raw.isBlank()) {
            return ID;
        }
        String value = raw.trim().toLowerCase(java.util.Locale.ROOT);
        for (WorkSort sort : values()) {
            if (sort.name().toLowerCase(java.util.Locale.ROOT).equals(value)) {
                return sort;
            }
        }
        throw ApiException.badRequest("sort 取值非法：" + raw + "（可选 id / rating / year）");
    }
}

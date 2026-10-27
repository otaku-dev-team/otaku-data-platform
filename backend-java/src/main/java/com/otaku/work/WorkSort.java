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
     * 在 {@code work_tag} 上的排序子句。
     *
     * <p>不能复用 {@link #orderBy(String)}：那张表的主键列叫 {@code work_ref} 而不是 {@code id}，
     * 直接套用会拼出 {@code t.id} 这种不存在的列。三种排序都能命中它自己的索引：
     * {@code id} 走主键 (tag, work_ref)，{@code rating} / {@code year} 走对应的二级索引。
     *
     * <p>列名**必须带别名**：{@code work} 与 {@code work_tag} 都有
     * {@code rating_value} / {@code release_year}，不限定表名时 MySQL 直接报
     * 「Column 'rating_value' in order clause is ambiguous」。
     */
    public String orderByOnTagTable(String alias) {
        String prefix = (alias == null || alias.isEmpty()) ? "" : alias + ".";
        return switch (this) {
            case ID -> prefix + "work_ref ASC";
            case RATING -> prefix + "rating_value DESC, " + prefix + "work_ref DESC";
            case YEAR -> prefix + "release_year DESC, " + prefix + "work_ref DESC";
        };
    }

    /**
     * 多标签（AND）查询的排序子句。
     *
     * <p>多标签必须 {@code GROUP BY work_ref} 才能做「命中全部标签」的判断，
     * 此时排序列也必须是聚合（或在 GROUP BY 里）。评分/年份对同一个作品的多行是**同值**
     * （冗余列写入时来自同一行的 work），所以 {@code MAX()} 取到的就是那个值，不改变语义。
     *
     * <p>代价：聚合排序无法复用单标签索引的有序性，会多一次 filesort。
     * 这是 AND 语义的固有成本（见 {@code WorkRepository.findPage} 的说明）。
     */
    public String orderByOnTagAggregate(String alias) {
        String prefix = (alias == null || alias.isEmpty()) ? "" : alias + ".";
        return switch (this) {
            case ID -> prefix + "work_ref ASC";
            case RATING -> "MAX(" + prefix + "rating_value) DESC, " + prefix + "work_ref DESC";
            case YEAR -> "MAX(" + prefix + "release_year) DESC, " + prefix + "work_ref DESC";
        };
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

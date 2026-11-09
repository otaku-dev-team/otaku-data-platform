package com.otaku.work.dto;

/**
 * 系列清单里的一件作品：作品卡 + **关系标签**（#557）。
 *
 * <p>为什么不再直接给 {@code List<WorkSummary>}：详情页的系列区每张卡都要标
 * 「前作 / 续作 / 衍生作 / 同系列」。把标签塞进 {@code WorkSummary} 会污染这个
 * 全站共用的卡片形状（收藏、搜索、资讯关联都用它）；放在外层包一层，
 * 客户端拿到的是「卡片 + 这张卡在这块里的身份」，语义正好。
 *
 * <p>{@code relation} 取值（对外固定 4 个，客户端据此显示中文，**不要自己按标题猜**）：
 * <ul>
 *   <li>{@code prequel} 前作</li>
 *   <li>{@code sequel} 续作</li>
 *   <li>{@code spin_off} 衍生作</li>
 *   <li>{@code same_series} 同系列（只有 series_key 相同、没有明确关系时的兜底）</li>
 * </ul>
 *
 * <p><b>当前实现的现实</b>：关系数据（前作/续作/衍生作）还没落库——数据集 schema 里
 * 有 {@code work_relations} 表，但 publisher 不写它、后端也没导入。所以现在
 * **所有条目都是 {@code same_series}**，这是准确的（它们确实同系列），不是占位假数据。
 * 关系数据落地后这里只会多出另外三个取值，形状不变。
 */
public record SeriesItemDto(
        WorkSummaryDto work,
        String relation
) {

    public static final String PREQUEL = "prequel";
    public static final String SEQUEL = "sequel";
    public static final String SPIN_OFF = "spin_off";
    public static final String SAME_SERIES = "same_series";

    public static SeriesItemDto sameSeries(WorkSummaryDto work) {
        return new SeriesItemDto(work, SAME_SERIES);
    }
}

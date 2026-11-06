package com.otaku.persona.dto;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;

/**
 * 阿宅画像的对外形状（#401 / #375）。
 *
 * <p>字段全部走 Jackson 的 SNAKE_CASE 策略，wire 上是
 * `type_weights` / `tag_weights` / `rating_tendency` / `recent_active` / `sample_size` / `generated_at`。
 *
 * <p><b>为什么权重是 0–1 而不是原始分</b>：客户端要画条形 / 雷达，直接要「相对强度」；
 * 原始分（浏览 1.0、看过 4.0、五星 3.0 相加）没有上限，不同用户之间也没法比。归一化按维度
 * 各自除以绝对值最大者，所以「最强的那个类型」恒为 1.0 或 -1.0。**负值保留**——低分作品的
 * 标签是「不喜欢」的证据，抹平成 0 等于把负反馈丢掉。
 *
 * <p><b>为什么要 `sample_size`</b>：只有 3 条行为的画像和 300 条的长得一样（都归一化到 1.0），
 * 客户端得知道该不该显示「你的口味还在形成中」。服务端不设门槛，把判断交给展示层。
 */
public final class PersonaDtos {

    private PersonaDtos() {
    }

    public record PersonaProfile(
            Map<String, Double> typeWeights,
            Map<String, Double> tagWeights,
            RatingTendency ratingTendency,
            List<String> recentActive,
            int sampleSize,
            OffsetDateTime generatedAt
    ) {
    }

    /**
     * 评分倾向。
     *
     * <p>`mean` 只在有评分时非空（`count = 0` 时给 null，不给 0.0——0.0 会被读成「平均 0 分」）；
     * `dist` 固定 10 个桶，下标 0 = 1 分、下标 9 = 10 分，**长度不随数据变**，
     * 客户端不用判空数组就能直接画柱状图。
     */
    public record RatingTendency(
            BigDecimal mean,
            int count,
            List<Integer> dist
    ) {
    }
}

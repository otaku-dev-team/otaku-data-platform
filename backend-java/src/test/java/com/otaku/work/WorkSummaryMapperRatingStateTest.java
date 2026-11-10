package com.otaku.work;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 评分三态（#588）：{@code main_rating} 为 {@code null} 时，详情页要能分出「票数不足」和「没有评分」。
 *
 * <p>这条状态**必须由后端给**：阈值 50 在库里已经有两份（{@link WorkService#MIN_RATING_COUNT}、
 * V30 生成列），再让客户端抄一份到 Dart 就是第三种漂移。
 *
 * <p>四个用例正好是四个分支：没有分、票数未知、票数不足、票数刚好达标。
 * 阈值边界（49 / 50）单独钉，是因为「差一票」最容易在重构时写成 {@code <=}。
 */
class WorkSummaryMapperRatingStateTest {

    private final WorkSummaryMapper mapper = new WorkSummaryMapper(null, null, null);

    @Test
    @DisplayName("来源没有评分 → none，且 main_rating 也为 null")
    void noRatingIsNone() {
        WorkRecord record = record(null, null);

        assertThat(mapper.ratingState(record)).isEqualTo(WorkSummaryMapper.RATING_NONE);
        assertThat(mapper.rating(record)).isNull();
    }

    @Test
    @DisplayName("有评分但票数未知 → rated（按可信处理，与 rating 口径一致）")
    void unknownCountIsRated() {
        WorkRecord record = record(new BigDecimal("7.8"), null);

        assertThat(mapper.ratingState(record)).isEqualTo(WorkSummaryMapper.RATING_RATED);
        assertThat(mapper.rating(record)).isNotNull();
    }

    @Test
    @DisplayName("票数 49 → insufficient：分数被口径藏掉，但状态说明原因是票数不足")
    void belowThresholdIsInsufficient() {
        WorkRecord record = record(new BigDecimal("9.5"), 49);

        assertThat(mapper.ratingState(record)).isEqualTo(WorkSummaryMapper.RATING_INSUFFICIENT);
        assertThat(mapper.rating(record))
                .as("票数不足时不展示分数——否则「1 个人打 10 分」会顶到榜首")
                .isNull();
    }

    @Test
    @DisplayName("票数 50 → rated：阈值是「≥」，边界那一票必须是达标的")
    void atThresholdIsRated() {
        WorkRecord record = record(new BigDecimal("8.1"), 50);

        assertThat(mapper.ratingState(record)).isEqualTo(WorkSummaryMapper.RATING_RATED);
        assertThat(mapper.rating(record)).isNotNull();
    }

    @Test
    @DisplayName("状态与分数永远自洽：说 rated 就一定给了分数，说给了分数就一定是 rated")
    void stateNeverContradictsRating() {
        for (BigDecimal value : new BigDecimal[]{null, new BigDecimal("7.8")}) {
            for (Integer count : new Integer[]{null, 0, 49, 50, 1200}) {
                WorkRecord record = record(value, count);
                boolean shown = mapper.rating(record) != null;

                assertThat(mapper.ratingState(record).equals(WorkSummaryMapper.RATING_RATED))
                        .as("value=%s count=%s 时状态与 main_rating 不一致："
                                + "两者一旦分头判阈值，就会出现「分数展示了、状态说不达标」", value, count)
                        .isEqualTo(shown);
            }
        }
    }

    /** 只填评分相关的三列，其余为 null——这几个方法不碰别的字段。 */
    private static WorkRecord record(BigDecimal ratingValue, Integer ratingCount) {
        return new WorkRecord(
                1L, "W-abc123", "anime", "标题", null, null, null, null, null, null,
                null, null, null, null,
                ratingValue, "0-10", "otaku_site", ratingCount,
                "otaku_site", "476", null, null, null, null);
    }
}

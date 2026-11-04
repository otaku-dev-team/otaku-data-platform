package com.otaku.mockseed;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 种子的两个「不测就会静默出错」的性质：**可复现**、**评分真的跟口味相关**。
 *
 * <p>如果评分与口味无关，后面调推荐权重时就会拿一条自造的假相关去拟合——
 * 数字看着漂亮，上线全错。所以这条相关性必须有测试钉住。
 */
class MockTasteGeneratorTest {

    private static final List<String> TAGS =
            List.of("机甲", "日常", "奇幻", "悬疑", "音乐", "运动", "恋爱", "科幻");
    private static final List<Integer> WEIGHTS = List.of(900, 800, 700, 600, 500, 400, 300, 200);

    @Test
    @DisplayName("同一个种子 → 同一串口味，换种子就变")
    void sameSeedGivesSameTaste() {
        List<String> a = new MockTasteGenerator(42).pickTaste(TAGS, WEIGHTS, 3);
        List<String> b = new MockTasteGenerator(42).pickTaste(TAGS, WEIGHTS, 3);
        List<String> c = new MockTasteGenerator(43).pickTaste(TAGS, WEIGHTS, 3);

        assertThat(a).isEqualTo(b);
        assertThat(c).isNotEqualTo(a);
    }

    @Test
    @DisplayName("口味标签互不重复")
    void tasteHasNoDuplicates() {
        List<String> taste = new MockTasteGenerator(7).pickTaste(TAGS, WEIGHTS, 4);

        assertThat(taste).hasSize(4).doesNotHaveDuplicates();
    }

    @Test
    @DisplayName("命中口味越多，平均评分越高（否则推荐学到的就是假相关）")
    void ratingGrowsWithTasteHits() {
        MockTasteGenerator rng = new MockTasteGenerator(2026);
        List<Double> zero = new ArrayList<>();
        List<Double> two = new ArrayList<>();
        for (int i = 0; i < 400; i++) {
            zero.add(rng.rating(0));
            two.add(rng.rating(2));
        }

        double meanZero = zero.stream().mapToDouble(Double::doubleValue).average().orElseThrow();
        double meanTwo = two.stream().mapToDouble(Double::doubleValue).average().orElseThrow();

        assertThat(meanTwo)
                .as("命中 2 个口味标签的均分应明显高于 0 个（实测约 +2.0）")
                .isGreaterThan(meanZero + 1.5);
        assertThat(zero).allSatisfy(v -> assertThat(v).isBetween(1.0, 10.0));
        assertThat(two).allSatisfy(v -> assertThat(v).isBetween(1.0, 10.0));
    }

    @Test
    @DisplayName("浏览数是长尾的：平均值明显低于区间中点")
    void viewCountIsLongTailed() {
        MockTasteGenerator rng = new MockTasteGenerator(5);
        double sum = 0;
        for (int i = 0; i < 2000; i++) {
            sum += rng.viewCount(8, 40);
        }
        double mean = sum / 2000;

        assertThat(mean)
                .as("幂律采样下均值应低于区间中点 24（实测约 16）")
                .isLessThan(24);
    }
}

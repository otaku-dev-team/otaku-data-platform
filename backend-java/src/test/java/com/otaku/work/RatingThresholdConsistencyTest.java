package com.otaku.work;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.core.io.ClassPathResource;

import java.nio.charset.StandardCharsets;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * #383 的票数阈值在**两处**存在，必须一致：
 *
 * <ul>
 *   <li>{@link WorkService#MIN_RATING_COUNT} —— 决定「展不展示评分」；</li>
 *   <li>{@code V30__work_rating_sort.sql} 里生成列的 {@code rating_count < 50} —— 决定「排序按 0 还是按原分」。</li>
 * </ul>
 *
 * <p>排序是 SQL 表达式，读不到 Java 常量，所以只能靠这个测试守着。
 * 只改一处不会让任何功能测试变红，只会让「分藏起来了、排名还按原分」这种错位静默上线——
 * 这正是最难在验收里发现的一类问题。
 */
class RatingThresholdConsistencyTest {

    private static final String MIGRATION = "db/migration/V30__work_rating_sort.sql";

    @Test
    @DisplayName("V30 生成列的票数阈值与 WorkService.MIN_RATING_COUNT 相同，且只有一处阈值")
    void migrationThresholdMatchesJavaConstant() throws Exception {
        String sql;
        try (var in = new ClassPathResource(MIGRATION).getInputStream()) {
            sql = new String(in.readAllBytes(), StandardCharsets.UTF_8);
        }

        assertThat(sql)
                .as("迁移里应出现与 Java 常量相同的阈值")
                .contains("rating_count < " + WorkService.MIN_RATING_COUNT);

        // 注释里也会写到阈值（说明口径），所以只数**可执行语句**里的出现次数：
        // 出现两次就说明有人复制粘贴了第二处阈值，两处将来一定会分叉。
        String executable = sql.lines()
                .filter(line -> !line.stripLeading().startsWith("--"))
                .collect(java.util.stream.Collectors.joining("\n"));
        int occurrences = executable.split("rating_count <", -1).length - 1;
        assertThat(occurrences)
                .as("阈值只应出现一次（生成列表达式里）")
                .isEqualTo(1);
    }
}

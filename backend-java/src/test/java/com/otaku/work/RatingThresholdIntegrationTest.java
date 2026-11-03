package com.otaku.work;

import com.otaku.work.dto.WorkSummaryDto;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.ActiveProfiles;

import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.stream.Collectors;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 评分口径（#383）：低票作品不展示评分、不进评分排序。
 *
 * <p>为什么必须连真库：这里验的是 **V30 生成列 {@code rating_sort} + 索引**真的按预期排。
 * mock 掉仓储只能证明「ORDER BY 字符串拼对了」，证不了「9.9 分 10 票确实排在 8.0 分 1000 票之后」——
 * 而后者才是这个 issue 要解决的事（「1 个人打 10 分占榜首」）。
 *
 * <p>三档口径各一条样本：
 * <ul>
 *   <li>票数 10 → 排序按 0、对外 {@code rating} 为 null；</li>
 *   <li>票数 1000 → 照常 8.0；</li>
 *   <li>票数未知（null）→ 照常 7.0（回填跑到一半时不能半屏没分）。</li>
 * </ul>
 */
@SpringBootTest
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3311）后重跑")
class RatingThresholdIntegrationTest {

    private static final String PREFIX = "it-rating-";
    private static final String SOURCE = "otaku_site";

    @Autowired
    private WorkRepository repository;

    @Autowired
    private WorkService workService;

    @Autowired
    private CountCache countCache;

    @Autowired
    private JdbcTemplate jdbc;

    @AfterEach
    void cleanUp() {
        countCache.invalidateAll();
        jdbc.update("DELETE FROM work_tag WHERE work_ref IN"
                + " (SELECT id FROM work WHERE source_id LIKE ?)", PREFIX + "%");
        jdbc.update("DELETE FROM work WHERE source_id LIKE ?", PREFIX + "%");
    }

    @Test
    @DisplayName("低票按 0 参与排序：9.9 分 10 票排在 8.0 分 1000 票之后，票数未知的按原分")
    void lowVoteSortsAsZeroButUnknownKeepsRating() {
        insert("low", "9.90", 10);
        insert("ok", "8.00", 1000);
        insert("unknown", "7.00", null);

        List<WorkRecord> rows = repository.findPage(null, null, null, WorkSort.RATING, null, null, 50, 0)
                .stream()
                .filter(record -> record.sourceId().startsWith(PREFIX))
                .toList();

        assertThat(rows).extracting(WorkRecord::sourceId)
                .as("1000 票 8.0 → 未知票数 7.0（按原分） → 10 票 9.9（按 0）")
                .containsExactly(PREFIX + "ok", PREFIX + "unknown", PREFIX + "low");
    }

    @Test
    @DisplayName("对外 rating：票数不足的为 null，票数未知/达标的照常返回")
    void serviceHidesOnlyLowVoteRatings() {
        insert("low", "9.90", 10);
        insert("ok", "8.00", 1000);
        insert("unknown", "7.00", null);

        Map<String, WorkSummaryDto> bySourceId = workService.list(null, null, null, "rating", null, 1, 50)
                .items().stream()
                .filter(item -> item.workId() != null)
                .collect(Collectors.toMap(WorkSummaryDto::workId, item -> item));

        // 用 title 反查 work_id：列表项只有 work_id，没有 source_id
        Map<String, String> workIdBySourceId = jdbc.query(
                "SELECT work_id, source_id FROM work WHERE source_id LIKE ?",
                (rs, rowNum) -> Map.entry(rs.getString("work_id"), rs.getString("source_id")),
                PREFIX + "%")
                .stream()
                .collect(Collectors.toMap(Map.Entry::getValue, Map.Entry::getKey));

        assertThat(bySourceId.get(workIdBySourceId.get(PREFIX + "low")).mainRating()).isNull();
        assertThat(bySourceId.get(workIdBySourceId.get(PREFIX + "ok")).mainRating()).isNotNull();
        assertThat(bySourceId.get(workIdBySourceId.get(PREFIX + "unknown")).mainRating()).isNotNull();
    }

    private void insert(String suffix, String ratingValue, Integer ratingCount) {
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        String sourceId = PREFIX + suffix;
        repository.insert(new WorkRecord(
                null,
                "W-" + UUID.randomUUID().toString().replace("-", "").substring(0, 20),
                "anime",
                "评分口径样本 " + suffix,
                null,
                2024,
                null, null, null, null,
                null, null, null,
                "[]",
                new BigDecimal(ratingValue), "0-10", SOURCE,
                null,   // rating_count 不由导入写，下面单独 UPDATE（与回填脚本同一条路径）
                SOURCE, sourceId, null,
                now, now, null));

        if (ratingCount != null) {
            jdbc.update("UPDATE work SET rating_count = ? WHERE source_id = ?", ratingCount, sourceId);
        }
    }
}

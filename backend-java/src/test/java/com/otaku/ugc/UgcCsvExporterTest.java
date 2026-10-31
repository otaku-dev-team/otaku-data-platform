package com.otaku.ugc;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.time.LocalDateTime;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 三份导出的 CSV 形状（不连库）。
 *
 * <p>为什么单独测：集成测试要真 MySQL，本地默认跳过；而「空值该输出空串而不是 null」
 * 这种事一旦写错，站主拿到的是字面量 "null"，而且要到真导出时才发现。
 */
class UgcCsvExporterTest {

    private static final LocalDateTime T = LocalDateTime.of(2026, 10, 31, 12, 0, 0);

    @Test
    @DisplayName("点评：只打分（body=null）与只写文字（rating=null）都输出空串，不写 null")
    void reviewNullsBecomeEmpty() {
        String csv = UgcCsvExporter.toReviewCsv(List.of(
                new UgcReviewRepository.ExportRow(1, "s", "W-1", "作品", "alice", 8, null,
                        "published", T, null),
                new UgcReviewRepository.ExportRow(2, "s", "W-1", "作品", "bob", null, "只写文字",
                        "published", T, null)));

        assertThat(csv).startsWith("review_id,work_id,work_title,author,rating,status,created_at,edited_at,body");
        assertThat(csv).doesNotContain("null");
        assertThat(csv).contains("1,W-1,作品,alice,8,published,");
        assertThat(csv).contains(",bob,,published,");
    }

    @Test
    @DisplayName("举报：理由里的逗号与引号按 RFC 4180 转义")
    void reportEscapes() {
        String csv = UgcCsvExporter.toReportCsv(List.of(
                new UgcReportRepository.ReportRow(7, "s", 42, "W-1", "作品", "bob",
                        "被举报的正文", "他骂人,\"很难听\"", "open", T)));

        assertThat(csv).startsWith("report_id,comment_id,work_id,work_title,reporter,reason,status,created_at");
        assertThat(csv).contains("\"他骂人,\"\"很难听\"\"\"");
    }

    @Test
    @DisplayName("三份表头互不相同：合在一起会让站主分不清哪列对哪行")
    void headersDiffer() {
        assertThat(UgcCsvExporter.COMMENT_HEADER).isNotEqualTo(UgcCsvExporter.REVIEW_HEADER);
        assertThat(UgcCsvExporter.REVIEW_HEADER).contains("rating");
        assertThat(UgcCsvExporter.REPORT_HEADER).contains("reason");
    }
}

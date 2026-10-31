package com.otaku.ugc;

import java.util.List;

/**
 * 把 UGC 导出成 CSV（#240 B2c：数据交还客户的硬要求）。
 *
 * <p>为什么单独一个纯函数：CSV 的坑全在转义上——正文里有逗号、引号、换行都很常见，
 * 转义写错会让导出的文件在 Excel 里错列，而站主拿它当「数据交还」的凭据。
 *
 * <p>规则（RFC 4180）：字段里出现 {@code , " \r \n} 之一时整体用双引号包起来，
 * 内部的双引号翻倍。首行是表头。
 *
 * <p><b>为什么有三份表</b>：下线时要删三张表（{@code ugc_comment} / {@code ugc_review} /
 * {@code ugc_report}），「交还」就必须也是三份——否则删掉的东西从来没交出去过。
 * 2026-10-31 演练实测：导出只有评论，点评与举报不在里面，而删除脚本三张表都删。
 * 三种行的字段天然不同（点评有评分、举报有理由），硬塞进一张表站主看不懂哪列对哪行。
 */
final class UgcCsvExporter {

    static final String[] COMMENT_HEADER = {"comment_id", "parent_id", "work_id", "work_title",
            "author", "status", "created_at", "body"};

    static final String[] REVIEW_HEADER = {"review_id", "work_id", "work_title", "author",
            "rating", "status", "created_at", "edited_at", "body"};

    static final String[] REPORT_HEADER = {"report_id", "comment_id", "work_id", "work_title",
            "reporter", "reason", "status", "created_at"};

    private UgcCsvExporter() {
    }

    static String toCsv(List<UgcRepository.ConsoleRow> rows) {
        StringBuilder csv = new StringBuilder();
        csv.append(String.join(",", COMMENT_HEADER)).append("\r\n");
        for (UgcRepository.ConsoleRow row : rows) {
            csv.append(escape(String.valueOf(row.id()))).append(',')
                    // 顶层评论留空、回复填父 id：站主拿到文件能自己重建楼层，不必回来问我们
                    .append(escape(row.parentId() == null ? "" : String.valueOf(row.parentId()))).append(',')
                    .append(escape(row.workId())).append(',')
                    .append(escape(row.workTitle())).append(',')
                    .append(escape(row.username())).append(',')
                    .append(escape(row.status())).append(',')
                    .append(escape(row.createdAt() == null ? "" : row.createdAt().toString())).append(',')
                    .append(escape(row.body())).append("\r\n");
        }
        return csv.toString();
    }

    /**
     * 点评一份。
     *
     * <p>{@code rating} 留空 = 只写了文字没打分；{@code body} 留空 = 只打了分没写文字。
     * 两个都可能为空，**空不等于导错了**。
     */
    static String toReviewCsv(List<UgcReviewRepository.ExportRow> rows) {
        StringBuilder csv = new StringBuilder();
        csv.append(String.join(",", REVIEW_HEADER)).append("\r\n");
        for (UgcReviewRepository.ExportRow row : rows) {
            csv.append(escape(String.valueOf(row.id()))).append(',')
                    .append(escape(row.workId())).append(',')
                    .append(escape(row.workTitle())).append(',')
                    .append(escape(row.username())).append(',')
                    .append(escape(row.rating() == null ? "" : String.valueOf(row.rating()))).append(',')
                    .append(escape(row.status())).append(',')
                    .append(escape(row.createdAt() == null ? "" : row.createdAt().toString())).append(',')
                    .append(escape(row.editedAt() == null ? "" : row.editedAt().toString())).append(',')
                    .append(escape(row.body())).append("\r\n");
        }
        return csv.toString();
    }

    /**
     * 举报工单一份。
     *
     * <p>只带被举报评论的 id，不带它的正文：正文在评论那份文件里（`status=all` 含已删）。
     * 两份文件靠 {@code comment_id} 对得上，站主不用在一个文件里读两遍同样的字。
     */
    static String toReportCsv(List<UgcReportRepository.ReportRow> rows) {
        StringBuilder csv = new StringBuilder();
        csv.append(String.join(",", REPORT_HEADER)).append("\r\n");
        for (UgcReportRepository.ReportRow row : rows) {
            csv.append(escape(String.valueOf(row.id()))).append(',')
                    .append(escape(String.valueOf(row.commentId()))).append(',')
                    .append(escape(row.workId())).append(',')
                    .append(escape(row.workTitle())).append(',')
                    .append(escape(row.author())).append(',')
                    .append(escape(row.reason())).append(',')
                    .append(escape(row.status())).append(',')
                    .append(escape(row.createdAt() == null ? "" : row.createdAt().toString())).append("\r\n");
        }
        return csv.toString();
    }

    /** 只在必要时加引号：不是所有字段都套引号，导出文件更好读也好 diff。 */
    static String escape(String raw) {
        if (raw == null || raw.isEmpty()) {
            return "";
        }
        boolean needsQuotes = raw.indexOf(',') >= 0 || raw.indexOf('"') >= 0
                || raw.indexOf('\n') >= 0 || raw.indexOf('\r') >= 0;
        if (!needsQuotes) {
            return raw;
        }
        return '"' + raw.replace("\"", "\"\"") + '"';
    }
}

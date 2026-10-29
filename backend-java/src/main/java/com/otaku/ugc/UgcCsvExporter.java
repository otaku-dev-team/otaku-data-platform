package com.otaku.ugc;

import java.util.List;

/**
 * 把评论导出成 CSV（#240 B2c：数据交还客户的硬要求）。
 *
 * <p>为什么单独一个纯函数：CSV 的坑全在转义上——正文里有逗号、引号、换行都很常见，
 * 转义写错会让导出的文件在 Excel 里错列，而站主拿它当「数据交还」的凭据。
 *
 * <p>规则（RFC 4180）：字段里出现 {@code , " \r \n} 之一时整体用双引号包起来，
 * 内部的双引号翻倍。首行是表头。
 */
final class UgcCsvExporter {

    static final String[] HEADER = {"comment_id", "work_id", "work_title", "author", "status",
            "created_at", "body"};

    private UgcCsvExporter() {
    }

    static String toCsv(List<UgcRepository.ConsoleRow> rows) {
        StringBuilder csv = new StringBuilder();
        csv.append(String.join(",", HEADER)).append("\r\n");
        for (UgcRepository.ConsoleRow row : rows) {
            csv.append(escape(String.valueOf(row.id()))).append(',')
                    .append(escape(row.workId())).append(',')
                    .append(escape(row.workTitle())).append(',')
                    .append(escape(row.username())).append(',')
                    .append(escape(row.status())).append(',')
                    .append(escape(row.createdAt() == null ? "" : row.createdAt().toString())).append(',')
                    .append(escape(row.body())).append("\r\n");
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

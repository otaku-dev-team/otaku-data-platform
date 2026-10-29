package com.otaku.ugc.dto;

/**
 * 举报工单（提交后的回执）。只回三个字段：举报人不需要看到队列状态机，
 * 但要知道「提交成功」以及对应哪条评论。
 */
public record CommentReportDto(String reportId, String commentId, String status) {
}

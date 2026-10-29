package com.otaku.ugc.dto;

/**
 * 举报一条评论。
 *
 * <p>{@code reason} 是用户填的**纯文本**（1–200 字），只给站主/平台处置时看，不对外展示。
 * 同一个人对同一条评论只会有一张工单：重复提交返回原工单，不报错。
 */
public record CommentReportRequest(String commentId, String reason) {
}

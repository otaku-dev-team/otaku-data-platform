package com.otaku.ugc.dto;

import java.time.Instant;
import java.util.List;

/**
 * 一条评论（对外形状）。字段刻意少：客户端只需要能渲染一条评论，不需要作者 id、
 * 站点键、状态机——那些是内部实现，暴露出去只会让客户端跟着我们的状态改名。
 *
 * <p>{@code status} 是评论状态：公开列表里只会出现 {@code published}；
 * 发评论的响应可能是 {@code pending}（站点开了「先审后发」），客户端据此提示「待审核」。
 *
 * <p>{@code author} 是用户名（不是昵称体系，B1 没有昵称）；已注销/被删用户的评论
 * 目前不会出现（用户删除不在本期），所以这里不做 null 兜底文案。
 *
 * <p>B2c 起一条评论可能是回复：
 * <ul>
 *   <li>{@code parentId}：回复的目标顶层评论 id；顶层评论为 {@code null}；</li>
 *   <li>{@code replyCount} / {@code replies}：**只有顶层评论**才有——前者是已发布回复总数，
 *       后者是其中最早的若干条（服务端截断，避免一次拉全楼）；回复自身这两个字段为 null / 空数组。</li>
 * </ul>
 * 只做一层：回复的 {@code parentId} 永远指向顶层评论，不会出现「回复的回复」。
 *
 * <p>{@code editedAt} 非空表示**作者改过正文**（站主的隐藏/恢复不算编辑，那走 updated_at）。
 * 客户端据此显示「已编辑」，审核侧据此判断是否需要重看。
 */
public record UgcCommentDto(
        String commentId,
        String workId,
        String author,
        String body,
        String status,
        Instant createdAt,
        Instant editedAt,
        String parentId,
        Integer replyCount,
        List<UgcCommentDto> replies
) {
    /** 顶层评论：带回复数与内嵌回复；回复自身用 {@link #reply}。 */
    public static UgcCommentDto floor(String commentId, String workId, String author, String body,
                                     String status, Instant createdAt, Instant editedAt,
                                     int replyCount, List<UgcCommentDto> replies) {
        return new UgcCommentDto(commentId, workId, author, body, status, createdAt, editedAt, null,
                replyCount, replies == null ? List.of() : replies);
    }

    /** 一条回复：不带 reply_count / replies（层数只有一层，嵌套字段没有读者）。 */
    public static UgcCommentDto reply(String commentId, String workId, String author, String body,
                                     String status, Instant createdAt, Instant editedAt,
                                     String parentId) {
        return new UgcCommentDto(commentId, workId, author, body, status, createdAt, editedAt,
                parentId, null, List.of());
    }
}

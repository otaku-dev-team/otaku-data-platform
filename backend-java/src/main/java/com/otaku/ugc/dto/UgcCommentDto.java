package com.otaku.ugc.dto;

import java.time.Instant;

/**
 * 一条评论（对外形状）。字段刻意少：客户端只需要能渲染一条评论，不需要作者 id、
 * 站点键、状态机——那些是内部实现，暴露出去只会让客户端跟着我们的状态改名。
 *
 * <p>{@code author} 是用户名（不是昵称体系，B1 没有昵称）；已注销/被删用户的评论
 * 目前不会出现（用户删除不在本期），所以这里不做 null 兜底文案。
 */
public record UgcCommentDto(
        String commentId,
        String workId,
        String author,
        String body,
        Instant createdAt
) {
}

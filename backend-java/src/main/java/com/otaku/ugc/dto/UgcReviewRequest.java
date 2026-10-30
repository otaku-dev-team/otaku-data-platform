package com.otaku.ugc.dto;

/**
 * 发表点评的请求体。
 *
 * <p>{@code workId} 放 body 的理由与评论一致：写接口统一挂在 {@code /api/me/**} 下，
 * 由 AuthFilter 统一鉴权，路径里不再嵌作品 id。
 *
 * <p>一人一条：同一作品已有点评时返回 {@code 409 REVIEW_EXISTS}，要改走 PATCH。
 */
public record UgcReviewRequest(String workId, Integer rating, String body) {
}

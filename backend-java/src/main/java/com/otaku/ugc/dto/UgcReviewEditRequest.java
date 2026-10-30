package com.otaku.ugc.dto;

/**
 * 修改点评的请求体。
 *
 * <p>两个字段都可省略，但**合并后**至少要有一项非空（只打分、只写评都行）。
 * 与评论的编辑一致：作品与作者不可改。
 */
public record UgcReviewEditRequest(Integer rating, String body) {
}

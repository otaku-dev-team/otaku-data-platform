package com.otaku.ugc.dto;

/**
 * 改评论正文的请求体。
 *
 * <p>只允许改 {@code body}：作品归属、作者、父评论都不可变——
 * 允许改 {@code parent_id} 等于「把一条回复搬走」，会让别人的楼层缺口，
 * 也确实没有这个需求（要换个位置说，删了重发即可）。
 *
 * <p>校验与发评论一致：去首尾空白后为空 → 400；超过 1000 字 → 400，不截断。
 */
public record UgcCommentEditRequest(String body) {
}

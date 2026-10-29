package com.otaku.ugc.dto;

/**
 * 发评论的请求体。{@code workId} 放 body 而不是路径，是因为写接口统一挂在
 * {@code /api/me/**} 下——那里由 AuthFilter 统一校验会话，路径里再嵌一层作品 id
 * 只会让「哪个 id 是资源、哪个是参数」变得含糊。
 *
 * <p>{@code body} 是**纯文本**：客户端不得按 HTML/Markdown 渲染，服务端也不解析。
 * 长度上限 1000（与列宽一致），超出返回 400 而不是截断——截断会悄悄改用户写的内容。
 */
public record UgcCommentRequest(String workId, String body) {
}

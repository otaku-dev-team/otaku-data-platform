package com.otaku.ugc.dto;

/**
 * 发评论 / 发回复的请求体。{@code work_id} 放 body 而不是路径，是因为写接口统一挂在
 * {@code /api/me/**} 下——那里由 AuthFilter 统一校验会话，路径里再嵌一层作品 id
 * 只会让「哪个 id 是资源、哪个是参数」变得含糊。
 *
 * <p>{@code body} 是**纯文本**：客户端不得按 HTML/Markdown 渲染，服务端也不解析。
 * 长度上限 1000（与列宽一致），超出返回 400 而不是截断——截断会悄悄改用户写的内容。
 *
 * <p>{@code parent_id} 为空 = 发顶层评论；有值 = 回复那条顶层评论。
 * 只允许一层：指向一条回复会被 400 拒掉（见 {@code UgcService#create}）。
 * 两参构造器保留给「发顶层评论」的调用点，语义等价于 {@code parent_id = null}。
 */
public record UgcCommentRequest(String workId, String body, String parentId) {

    public UgcCommentRequest(String workId, String body) {
        this(workId, body, null);
    }
}

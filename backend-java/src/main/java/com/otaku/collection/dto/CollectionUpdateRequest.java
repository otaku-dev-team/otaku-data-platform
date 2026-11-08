package com.otaku.collection.dto;

/**
 * 收藏/改状态的请求体。
 * 只接受"目标状态"这一个字段：客户端提交明确结果，而不是"切换"，
 * 这样重试同一个请求不会反向操作（project-plan-v2 §5.2）。
 * status 可为 null，表示收藏但不设状态。
 *
 * <p>{@code source}（#506）标记这条是谁写的：`user`（默认，用户操作）/ `quiz`（冷启动漏斗种子）。
 * 省略就是 `user`——老客户端不受影响。**种子不能覆盖用户操作**：同一个 work 上已有
 * `source=user` 的行时，`quiz` 的写入会被忽略（返回当前状态，不报错）。
 */
public record CollectionUpdateRequest(String status, String source) {
}

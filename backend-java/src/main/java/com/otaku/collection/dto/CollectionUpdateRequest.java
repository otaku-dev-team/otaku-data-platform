package com.otaku.collection.dto;

/**
 * 收藏/改状态的请求体。
 * 只接受"目标状态"这一个字段：客户端提交明确结果，而不是"切换"，
 * 这样重试同一个请求不会反向操作（project-plan-v2 §5.2）。
 * status 可为 null，表示收藏但不设状态。
 */
public record CollectionUpdateRequest(String status) {
}

package com.otaku.work.dto;

import java.util.List;

/**
 * 标签词表（{@code GET /api/tags}）的响应形状。
 *
 * <p>{@code total} 是**本次返回的条数**，不是词表总数——与首站语义一致（见
 * {@code docs/stage1-minimal-contract.md} §4.4.1）。这样客户端不需要再区分
 * 「有 limit」与「没有 limit」两种口径。
 */
public final class TagDtos {

    private TagDtos() {
    }

    /**
     * @param count 该标签下的作品数（当前快照；来源未提供标签的作品不计入）
     */
    public record TagItem(String name, long count) {
    }

    /**
     * @param type 请求里的 type 原样回显；省略时为 null（全部类型）
     */
    public record TagList(String type, long total, List<TagItem> items) {
    }
}

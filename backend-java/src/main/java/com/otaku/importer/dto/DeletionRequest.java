package com.otaku.importer.dto;

import java.util.List;

/**
 * 软删请求（契约 §「POST /internal/import/deletions」，方案见
 * {@code docs/deletion-semantics-proposal.md}）。
 *
 * <p>为什么单独一个端点而不是塞进接口②：② 是「写入这批数据」，删除是「这批不再存在」。
 * 合在一起，{@code on_missing} 三档、数组整体替换、500 上限全都要重新解释一遍；
 * 分开则两边契约一个字都不用改，而且删除可以独立重放——重发不会连带重跑写入。
 *
 * <p>{@code reason} 只入日志，不入库：删除动作本身可查（{@code work.deleted_at}），
 * 但「为什么删」是排障信息，写进业务表只会增加没有查询方的列。
 */
public record DeletionRequest(
        String source,
        String batchId,
        List<Item> items
) {

    public record Item(String sourceId, String reason) {
    }
}

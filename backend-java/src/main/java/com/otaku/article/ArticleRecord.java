package com.otaku.article;

import java.time.LocalDateTime;

/**
 * article 表的一行：一条最新资讯。
 *
 * <p>与 {@code WorkRecord} 的关键差异：资讯**不是作品**，没有 work_id 可言。
 * {@code sourceUrl} 存的是**原文链接**（如 ln-news.com），客户端用它跳回来源站——
 * 对应项目章程 G3「用户不被困在平台内」。资讯的价值在原文，不在我们复述一遍。
 *
 * <p>{@code relatedWorkIds} 是来源站「关联作品」区给的**站点作品 id 原文**，
 * 不回填本地 work_id：那区块是编辑推荐的周边作品，回填了会让客户端给出
 * 「本文对应这部作品」的错误跳转。留着是为了将来做关联时不必重新抓页面。
 *
 * <p>JSON 列（{@code tags} / {@code relatedWorkIds}）存原文并读出时归一，
 * 理由与 work.tags 一致：MySQL 会把 JSON 重新格式化后读出，
 * 用字符串比较判「是否变化」会让每次重跑都变成 updated。
 */
public record ArticleRecord(
        Long id,
        String articleId,
        String source,
        String sourceId,
        String title,
        String summary,
        String body,
        String category,
        LocalDateTime publishedAt,
        String sourceName,
        String sourceUrl,
        String coverUrl,
        String tagsJson,
        String relatedWorkIdsJson,
        LocalDateTime createdAt,
        LocalDateTime updatedAt
) {
}
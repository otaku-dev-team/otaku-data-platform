package com.otaku.work;

import java.math.BigDecimal;
import java.time.LocalDateTime;

/**
 * work 表的一行（内部模型，不直接序列化给客户端）。
 *
 * 几个刻意的设计：
 * - tagsJson 保留 SQL NULL 与 "[]" 的区别：NULL = 来源未提供（更新时不覆盖），
 *   "[]" = 明确无标签（可清空），见契约 2.3 与 4.4.3；
 * - coverSourceUrl 是来源站地址，永不出现在响应里；对外地址由 cover_url 重新拼；
 * - releaseYear 用包装类型 Integer：null = 来源未提供，不能退化成 0；
 * - aliasesJson 与 tagsJson 同构：NULL = 未提供（更新不覆盖）、"[]" = 明确没有（可清空）；
 * - media 保留来源原值，不做跨源枚举归一（各站词表不同，归一等于替来源定义分类）；
 * - episodes 用包装类型：0 无意义（导入层整条拒收），null 才是「未提供」；
 * - 时间统一存 UTC 的 LocalDateTime，出参时转 Instant（带 Z 的 RFC 3339）；
 * - deletedAt 是软删时间（#249）：null = 正常，非空 = 已下架。列表/搜索/筛选过滤掉，
 *   详情仍返回（`200 + deleted:true`），导入命中同一 (source, source_id) 时置空复活。
 */
public record WorkRecord(
        Long id,
        String workId,
        String workType,
        String title,
        String summary,
        Integer releaseYear,
        String titleOriginal,
        String aliasesJson,
        String media,
        Integer episodes,
        String coverSourceUrl,
        String coverCacheKey,
        LocalDateTime coverCachedAt,
        String tagsJson,
        BigDecimal ratingValue,
        String ratingScale,
        String ratingSource,
        String source,
        String sourceId,
        String sourceUrl,
        LocalDateTime createdAt,
        LocalDateTime updatedAt,
        LocalDateTime deletedAt
) {
}

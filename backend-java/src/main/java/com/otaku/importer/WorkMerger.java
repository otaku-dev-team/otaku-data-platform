package com.otaku.importer;

import com.otaku.work.WorkRecord;

import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.Objects;

/**
 * 创建与更新规则（契约 5.5 的核心）：
 *
 * - 命中 → 只覆盖本次"出现且非 null"的字段，未出现或为 null 的保留原值；
 * - tags 三态：null 不覆盖、[] 清空、有值替换；
 * - work_id / source / source_id / created_at 永不变；
 * - updated_at 只在内容真的变化时推进——否则验收 D2 的 unchanged 计数会变成 updated；
 * - 封面地址变了要清掉本地缓存键，强制下次重新回源。
 *
 * 这是一个纯函数，不碰数据库，所以能用单元测试把上面每条规则钉住。
 */
final class WorkMerger {

    private WorkMerger() {
    }

    record MergeResult(WorkRecord work, boolean changed) {
    }

    static WorkRecord newRecord(NormalizedItem item, String workId, String source, LocalDateTime now) {
        return new WorkRecord(
                null, workId, item.workType(), item.title(), item.summary(), item.releaseYear(),
                item.coverUrl(), null, null, item.tagsJson(),
                item.ratingValue(), item.ratingScale(), item.ratingSource(),
                source, item.sourceId(), item.sourceUrl(), now, now);
    }

    static MergeResult merge(WorkRecord old, NormalizedItem item) {
        String title = item.title() != null ? item.title() : old.title();
        String summary = item.summary() != null ? item.summary() : old.summary();
        Integer releaseYear = item.releaseYear() != null ? item.releaseYear() : old.releaseYear();
        String cover = item.coverUrl() != null ? item.coverUrl() : old.coverSourceUrl();
        boolean coverChanged = !Objects.equals(cover, old.coverSourceUrl());
        String cacheKey = coverChanged ? null : old.coverCacheKey();
        LocalDateTime cachedAt = coverChanged ? null : old.coverCachedAt();
        String tagsJson = item.tagsJson() != null ? item.tagsJson() : old.tagsJson();
        BigDecimal ratingValue = item.ratingValue() != null ? item.ratingValue() : old.ratingValue();
        String ratingScale = item.ratingScale() != null ? item.ratingScale() : old.ratingScale();
        String ratingSource = item.ratingSource() != null ? item.ratingSource() : old.ratingSource();
        String sourceUrl = item.sourceUrl() != null ? item.sourceUrl() : old.sourceUrl();

        boolean changed = coverChanged
                || !Objects.equals(title, old.title())
                || !Objects.equals(summary, old.summary())
                || !Objects.equals(releaseYear, old.releaseYear())
                || !Objects.equals(tagsJson, old.tagsJson())
                || !sameDecimal(ratingValue, old.ratingValue())
                || !Objects.equals(ratingScale, old.ratingScale())
                || !Objects.equals(ratingSource, old.ratingSource())
                || !Objects.equals(sourceUrl, old.sourceUrl());

        if (!changed) {
            return new MergeResult(old, false);
        }

        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        return new MergeResult(new WorkRecord(
                old.id(), old.workId(), old.workType(), title, summary, releaseYear,
                cover, cacheKey, cachedAt, tagsJson,
                ratingValue, ratingScale, ratingSource,
                old.source(), old.sourceId(), sourceUrl, old.createdAt(), now), true);
    }

    private static boolean sameDecimal(BigDecimal left, BigDecimal right) {
        if (left == null || right == null) {
            return left == right;
        }
        return left.compareTo(right) == 0;
    }
}

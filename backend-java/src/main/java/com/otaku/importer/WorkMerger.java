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
 * - 封面地址变了要清掉本地缓存键，强制下次重新回源；
 * - 软删行被重新写入 = 复活（#249）：deleted_at 置空，哪怕内容一模一样也要算 changed，
 *   否则会出现「重新导入了却搜不到」，而且不报任何错。
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
                item.titleOriginal(), item.aliasesJson(), item.media(), item.episodes(),
                item.coverUrl(), null, null, item.tagsJson(),
                item.ratingValue(), item.ratingScale(), item.ratingSource(),
                source, item.sourceId(), item.sourceUrl(), now, now, null);
    }

    static MergeResult merge(WorkRecord old, NormalizedItem item) {
        String title = item.title() != null ? item.title() : old.title();
        String summary = item.summary() != null ? item.summary() : old.summary();
        Integer releaseYear = item.releaseYear() != null ? item.releaseYear() : old.releaseYear();
        String titleOriginal = item.titleOriginal() != null ? item.titleOriginal() : old.titleOriginal();
        // aliases 与 tags 同构三态：null 不覆盖、"[]" 清空、有值替换。
        String aliasesJson = item.aliasesJson() != null ? item.aliasesJson() : old.aliasesJson();
        String media = item.media() != null ? item.media() : old.media();
        Integer episodes = item.episodes() != null ? item.episodes() : old.episodes();
        String cover = item.coverUrl() != null ? item.coverUrl() : old.coverSourceUrl();
        boolean coverChanged = !Objects.equals(cover, old.coverSourceUrl());
        String cacheKey = coverChanged ? null : old.coverCacheKey();
        LocalDateTime cachedAt = coverChanged ? null : old.coverCachedAt();
        String tagsJson = item.tagsJson() != null ? item.tagsJson() : old.tagsJson();
        BigDecimal ratingValue = item.ratingValue() != null ? item.ratingValue() : old.ratingValue();
        String ratingScale = item.ratingScale() != null ? item.ratingScale() : old.ratingScale();
        String ratingSource = item.ratingSource() != null ? item.ratingSource() : old.ratingSource();
        String sourceUrl = item.sourceUrl() != null ? item.sourceUrl() : old.sourceUrl();

        // 软删行（#249）收到同一条数据的写入 = 源站又有了它，必须复活：
        // 只把 deleted_at 置空并推进 updated_at，内容字段本身可能一个都没变。
        boolean resurrected = old.deletedAt() != null;
        boolean changed = resurrected
                || coverChanged
                || !Objects.equals(title, old.title())
                || !Objects.equals(summary, old.summary())
                || !Objects.equals(releaseYear, old.releaseYear())
                || !Objects.equals(titleOriginal, old.titleOriginal())
                || !Objects.equals(aliasesJson, old.aliasesJson())
                || !Objects.equals(media, old.media())
                || !Objects.equals(episodes, old.episodes())
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
                titleOriginal, aliasesJson, media, episodes,
                cover, cacheKey, cachedAt, tagsJson,
                ratingValue, ratingScale, ratingSource,
                old.source(), old.sourceId(), sourceUrl, old.createdAt(), now, null), true);
    }

    private static boolean sameDecimal(BigDecimal left, BigDecimal right) {
        if (left == null || right == null) {
            return left == right;
        }
        return left.compareTo(right) == 0;
    }
}

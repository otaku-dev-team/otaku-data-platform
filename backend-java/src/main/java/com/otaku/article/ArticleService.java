package com.otaku.article;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.article.dto.ArticleDtos.ArticleDetail;
import com.otaku.article.dto.ArticleDtos.ArticlePage;
import com.otaku.article.dto.ArticleDtos.ArticleRelated;
import com.otaku.article.dto.ArticleDtos.ArticleSummary;
import com.otaku.article.dto.ArticleDtos.Category;
import com.otaku.common.AdultPolicy;
import com.otaku.common.PageResponse;
import org.springframework.stereotype.Service;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;

/**
 * 最新资讯的公开接口。
 *
 * <p>分页而不是一次全给：资讯是持续增长的数据（站点每天几十条），
 * 全给会让客户端首屏把几个月的旧闻都拉一遍，而用户只想看最新的。
 * 列表按发布时间倒序，客户端「加载更多」即可。
 */
@Service
public class ArticleService {

    private static final int MAX_PAGE_SIZE = 50;
    private static final TypeReference<List<String>> STRING_LIST = new TypeReference<>() {
    };

    private final ArticleRepository repository;
    private final ObjectMapper objectMapper;

    private final AdultPolicy adultPolicy;

    private final ArticleRelatedIdsSemantics semantics;

    public ArticleService(ArticleRepository repository, ObjectMapper objectMapper, AdultPolicy adultPolicy,
                          ArticleRelatedIdsSemantics semantics) {
        this.repository = repository;
        this.objectMapper = objectMapper;
        this.adultPolicy = adultPolicy;
        this.semantics = semantics;
    }

    /**
     * 一页资讯。
     *
     * @param category 分类筛选；省略或空串表示不过滤
     */
    public ArticlePage list(String categoryParam, int pageParam, int pageSizeParam) {
        String category = categoryParam == null || categoryParam.isBlank()
                ? null
                : categoryParam.trim();

        int pageSize = clampPageSize(pageSizeParam);
        int page = Math.max(pageParam, 1);

        long total = repository.count(category);
        List<ArticleRecord> records = total == 0
                ? List.of()
                : repository.findPage(category, pageSize, (page - 1) * pageSize);

        List<ArticleSummary> items = new ArrayList<>(records.size());
        for (ArticleRecord record : records) {
            items.add(toSummary(record));
        }
        return new ArticlePage(total, page, pageSize,
                PageResponse.totalPages(total, pageSize), items);
    }

    /**
     * 作品→资讯（#409）：关联作品里含这个 subject id 的资讯，按发布时间倒序。
     *
     * <p>返回空有三种情况，响应形状都一样（{@code total=0} + 空 items）：
     * <ol>
     *   <li>这部作品本来就没有关联资讯；</li>
     *   <li>调用方给的 {@code subjectId} 为 null（非 bangumi 来源的作品，
     *       {@code related_work_ids} 里装的不是它的号）；</li>
     *   <li>数据还没切到 subject id（见 {@link ArticleRelatedIdsSemantics}）——
     *       这时宁可整块不显示，也不拿 content_id 去撞号。</li>
     * </ol>
     * 客户端对「空」的处理与「没有」一致：不渲染该区块。
     */
    public ArticlePage listForWorkSubject(String subjectId, int pageParam, int pageSizeParam) {
        int pageSize = clampPageSize(pageSizeParam);
        int page = Math.max(pageParam, 1);
        if (subjectId == null || subjectId.isBlank() || !semantics.resolvedToSubjectId()) {
            return new ArticlePage(0, page, pageSize, 0, List.of());
        }

        String normalized = subjectId.trim();
        long total = repository.countRelatedToWork(normalized);
        List<ArticleRecord> records = total == 0
                ? List.of()
                : repository.findRelatedToWork(normalized, pageSize, (page - 1) * pageSize);

        List<ArticleSummary> items = new ArrayList<>(records.size());
        for (ArticleRecord record : records) {
            items.add(toSummary(record));
        }
        return new ArticlePage(total, page, pageSize,
                PageResponse.totalPages(total, pageSize), items);
    }

    /** 每页条数：省略按 20，上限 50（与作品列表同口径，超了截断而不是报错）。 */
    private static int clampPageSize(int pageSizeParam) {
        return Math.min(Math.max(pageSizeParam <= 0 ? 20 : pageSizeParam, 1), MAX_PAGE_SIZE);
    }

    /** 详情。不存在返回 {@code null}，由控制器转 404。 */
    public ArticleDetail detail(String articleId) {
        if (articleId == null || articleId.isBlank()) {
            return null;
        }
        return repository.findByArticleId(articleId.trim()).map(this::toDetail).orElse(null);
    }

    /** 相关资讯的条数：默认 10、上限 20。再多就不叫「延伸阅读」了。 */
    static final int RELATED_DEFAULT = 10;
    static final int RELATED_MAX = 20;
    /** 候选取 limit 的 5 倍：SQL 只能按时间粗排，多取一些让打分有得挑。 */
    private static final int RELATED_CANDIDATE_FACTOR = 5;

    /**
     * 资讯↔资讯（#414）：同标签 / 同分类的「延伸阅读」。
     *
     * <p>打分：`共享标签数 × 2 + 同分类 × 1`，同分按发布时间倒序。
     * **同来源不计分**——同一来源的资讯本来就高度同质，把它当相似证据等于
     * 「只要是这家媒体的就相关」，噪声大于信息。
     *
     * <p>返回 {@code null} 表示源资讯不存在（控制器转 404）；返回空 items 表示
     * 源资讯既没标签也没分类，或候选全被过滤——两种都是 200。
     */
    public ArticleRelated related(String articleId, int limitParam) {
        if (articleId == null || articleId.isBlank()) {
            return null;
        }
        ArticleRecord source = repository.findByArticleId(articleId.trim()).orElse(null);
        if (source == null) {
            return null;
        }

        int limit = Math.min(Math.max(limitParam <= 0 ? RELATED_DEFAULT : limitParam, 1), RELATED_MAX);
        List<String> sourceTags = readTags(source.tagsJson());
        if (sourceTags == null) {
            sourceTags = List.of();
        }
        String tagsJson = sourceTags.isEmpty() ? null : source.tagsJson();
        String category = source.category() == null || source.category().isBlank()
                ? null
                : source.category();
        if (tagsJson == null && category == null) {
            return new ArticleRelated(List.of());
        }

        List<ArticleRecord> candidates = repository.findRelatedCandidates(
                source.articleId(), tagsJson, category, limit * RELATED_CANDIDATE_FACTOR);

        List<ScoredArticle> scored = new ArrayList<>();
        for (ArticleRecord candidate : candidates) {
            List<String> candidateTags = readTags(candidate.tagsJson());
            int shared = 0;
            if (candidateTags != null) {
                for (String tag : candidateTags) {
                    if (sourceTags.contains(tag)) {
                        shared++;
                    }
                }
            }
            double score = shared * 2.0
                    + (category != null && category.equals(candidate.category()) ? 1.0 : 0.0);
            if (score > 0) {
                scored.add(new ScoredArticle(candidate, score));
            }
        }
        scored.sort(Comparator.comparingDouble(ScoredArticle::score).reversed()
                .thenComparing(s -> s.record().publishedAt(),
                        Comparator.nullsLast(Comparator.reverseOrder())));

        List<ArticleSummary> items = scored.stream()
                .limit(limit)
                .map(s -> toSummary(s.record()))
                .toList();
        return new ArticleRelated(items);
    }

    private record ScoredArticle(ArticleRecord record, double score) {
    }

    /** 全部分类（条数多的在前）。空库返回空列表。 */
    public List<Category> categories() {
        List<Category> result = new ArrayList<>();
        for (String name : repository.findCategories()) {
            result.add(new Category(name, repository.count(name)));
        }
        return result;
    }

    private ArticleSummary toSummary(ArticleRecord record) {
        return new ArticleSummary(
                record.articleId(),
                record.title(),
                record.summary(),
                record.category(),
                formatTimestamp(record),
                record.sourceName(),
                record.sourceUrl(),
                record.coverUrl(),
                readTags(record.tagsJson()));
    }

    private ArticleDetail toDetail(ArticleRecord record) {
        return new ArticleDetail(
                record.articleId(),
                record.title(),
                record.summary(),
                record.body(),
                record.category(),
                formatTimestamp(record),
                record.sourceName(),
                record.sourceUrl(),
                record.coverUrl(),
                readTags(record.tagsJson()),
                readStringList(record.relatedWorkIdsJson()),
                // content_id → 本地作品 的解析归 #409（需先落 content_id→bangumi_id
                // 映射）。落地前显式给 null：客户端整块不渲染，而不是拿
                // related_work_ids 去猜本地 work_id（那是站点号，见 V9 / V28）。
                null);
    }

    /**
     * 发布时间转 ISO-8601 字符串。
     *
     * <p>库里存的是 UTC 无时区 {@code LocalDateTime}（与 work 表同口径）。
     * 这里显式按 UTC 解读再带上 {@code Z}：直接
     * {@code LocalDateTime.toString()} 出来的是裸时间，客户端会当本地时间解析，
     * 资讯列表按时间排序就会整体偏移。
     *
     * <p>没有发布时间时返回 null：客户端不渲染时间，也不该显示成一个伪造的日期。
     */
    private static String formatTimestamp(ArticleRecord record) {
        if (record.publishedAt() == null) {
            return null;
        }
        return record.publishedAt().atOffset(java.time.ZoneOffset.UTC).toString();
    }

    /** 读 JSON 数组列。解析不了当未提供：这一列是附加信息，不该让整条资讯读不出来。 */
    /**
     * 资讯标签。成人词同样剔除——资讯标签与作品标签是同一套体系（站点两处都指向
     * {@code /contents?tag=xxx}），别处藏了这里露出来就等于没藏。
     */
    private List<String> readTags(String json) {
        return adultPolicy.strip(readStringList(json));
    }

    private List<String> readStringList(String json) {
        if (json == null || json.isBlank()) {
            return null;
        }
        try {
            return objectMapper.readValue(json, STRING_LIST);
        } catch (Exception ex) {
            return null;
        }
    }
}
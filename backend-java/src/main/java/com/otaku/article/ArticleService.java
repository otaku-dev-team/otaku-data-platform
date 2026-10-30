package com.otaku.article;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.article.dto.ArticleDtos.ArticleDetail;
import com.otaku.article.dto.ArticleDtos.ArticlePage;
import com.otaku.article.dto.ArticleDtos.ArticleSummary;
import com.otaku.article.dto.ArticleDtos.Category;
import com.otaku.common.AdultTags;
import com.otaku.common.PageResponse;
import org.springframework.stereotype.Service;

import java.util.ArrayList;
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

    public ArticleService(ArticleRepository repository, ObjectMapper objectMapper) {
        this.repository = repository;
        this.objectMapper = objectMapper;
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

        int pageSize = Math.min(Math.max(pageSizeParam <= 0 ? 20 : pageSizeParam, 1), MAX_PAGE_SIZE);
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

    /** 详情。不存在返回 {@code null}，由控制器转 404。 */
    public ArticleDetail detail(String articleId) {
        if (articleId == null || articleId.isBlank()) {
            return null;
        }
        return repository.findByArticleId(articleId.trim()).map(this::toDetail).orElse(null);
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
                readStringList(record.relatedWorkIdsJson()));
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
        return AdultTags.strip(readStringList(json));
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
package com.otaku.work;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.common.ApiException;
import com.otaku.common.LikePattern;
import com.otaku.common.PageResponse;
import com.otaku.config.PublicUrlResolver;
import com.otaku.work.dto.RelatedWorksDto;
import com.otaku.work.dto.SourceRatingDto;
import com.otaku.work.dto.WorkDto;
import com.otaku.work.dto.WorkSummaryDto;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

import java.time.ZoneOffset;
import java.util.List;

/**
 * 作品查询（接口③④）。
 *
 * 与契约一一对应：page_size 上限 50 且超限截断不报错；page 越界返回空 items；
 * q 无结果返回 200 + 空数组；详情任何非法 work_id 都返回 404。
 */
@Service
public class WorkService {

    private static final Logger log = LoggerFactory.getLogger(WorkService.class);

    static final int DEFAULT_PAGE_SIZE = 20;
    static final int MAX_PAGE_SIZE = 50;
    private static final int MAX_QUERY_LENGTH = 100;
    private static final int MAX_WORK_ID_LENGTH = 64;

    /** 详情页推荐默认返回 6 条、最多 20 条——与来源站详情页的 6 条对齐，避免一次拉太多。 */
    static final int DEFAULT_RELATED_LIMIT = 6;
    static final int MAX_RELATED_LIMIT = 20;
    /** 只用前 5 个标签做匹配：标签太多的作品用全集去求交集，命中会退化成"全站"。 */
    private static final int MAX_BASIS_TAGS = 5;

    private static final TypeReference<List<String>> TAG_LIST = new TypeReference<>() {
    };

    private final WorkRepository repository;
    private final PublicUrlResolver publicUrlResolver;
    private final ObjectMapper objectMapper;

    public WorkService(WorkRepository repository, PublicUrlResolver publicUrlResolver,
                       ObjectMapper objectMapper) {
        this.repository = repository;
        this.publicUrlResolver = publicUrlResolver;
        this.objectMapper = objectMapper;
    }

    public PageResponse<WorkSummaryDto> list(String typeParam, String qParam, String sortParam,
                                             int page, int pageSize) {
        String workType = normalizeType(typeParam);
        String keyword = normalizeKeyword(qParam);
        WorkSort sort = WorkSort.parse(sortParam);

        int safePage = Math.max(page, 1);
        int safeSize = pageSize <= 0 ? DEFAULT_PAGE_SIZE : Math.min(pageSize, MAX_PAGE_SIZE);
        String pattern = keyword == null ? null : LikePattern.contains(keyword);

        long total = repository.count(workType, pattern);
        List<WorkSummaryDto> items = total == 0
                ? List.of()
                : repository.findPage(workType, pattern, sort, safeSize, (safePage - 1) * safeSize)
                        .stream()
                        .map(this::toSummary)
                        .toList();
        return PageResponse.of(safePage, safeSize, total, items);
    }

    /**
     * 同标签推荐（详情页底部）。
     *
     * <p>没有标签的作品返回空列表而不是报错——「推荐不出来」是正常状态，
     * 客户端据此不渲染该区块即可。作品本身不存在仍然 404，与详情一致。
     *
     * <p>{@code basis_tags} 回传实际用于匹配的标签，让客户端能显示
     * 「同题材：科幻、机战」这类理由，而不是给一堆无解释的卡片。
     */
    public RelatedWorksDto related(String workId, Integer limitParam) {
        WorkRecord current = requireWork(workId);
        int limit = limitParam == null || limitParam <= 0
                ? DEFAULT_RELATED_LIMIT
                : Math.min(limitParam, MAX_RELATED_LIMIT);
        List<String> tags = parseTags(current.tagsJson());
        if (tags == null || tags.isEmpty()) {
            return new RelatedWorksDto(List.of(), List.of());
        }
        List<String> basis = tags.size() > MAX_BASIS_TAGS ? tags.subList(0, MAX_BASIS_TAGS) : tags;
        List<WorkSummaryDto> items = repository
                .findRelated(current.id(), toTagsJson(basis), limit)
                .stream()
                .map(this::toSummary)
                .toList();
        return new RelatedWorksDto(basis, items);
    }

    /** 详情与相关推荐共用的「取作品或 404」逻辑。 */
    private WorkRecord requireWork(String workId) {
        if (workId == null || workId.isBlank() || workId.length() > MAX_WORK_ID_LENGTH) {
            // 契约 6.2：格式非法同样返回 404，不用 400 区分"存在与否"。
            throw ApiException.workNotFound();
        }
        return repository.findByWorkId(workId.trim())
                .orElseThrow(ApiException::workNotFound);
    }

    /** 把标签列表序列化成 JSON 数组文本，供 JSON_OVERLAPS 使用。 */
    private String toTagsJson(List<String> tags) {
        try {
            return objectMapper.writeValueAsString(tags);
        } catch (Exception ex) {
            // 标签都来自库里已解析过的字符串，序列化失败说明数据本身异常，按"没有标签"处理。
            log.warn("标签无法序列化，推荐按空处理：{}", ex.getMessage());
            return null;
        }
    }

    public WorkDto detail(String workId) {
        WorkRecord record = requireWork(workId);
        return new WorkDto(
                record.workId(),
                record.workType(),
                record.title(),
                record.summary(),
                record.releaseYear(),
                coverUrl(record),
                parseTags(record.tagsJson()),
                toRating(record),
                record.source(),
                record.sourceId(),
                record.sourceUrl(),
                record.updatedAt() == null ? null : record.updatedAt().toInstant(ZoneOffset.UTC));
    }

    /** 封面地址永远指向本服务，客户端不直连来源站（契约 2.1、8.1）。 */
    public String coverUrl(WorkRecord record) {
        return coverUrl(record.workId(), record.coverSourceUrl());
    }

    /** 供收藏列表等其它视图复用：有来源地址才给平台代理地址。 */
    public String coverUrl(String workId, String coverSourceUrl) {
        if (coverSourceUrl == null) {
            return null;
        }
        return publicUrlResolver.baseUrl() + "/api/covers/" + workId;
    }

    private WorkSummaryDto toSummary(WorkRecord record) {
        return new WorkSummaryDto(
                record.workId(),
                record.workType(),
                record.title(),
                record.releaseYear(),
                coverUrl(record),
                parseTags(record.tagsJson()),
                toRating(record));
    }

    private static SourceRatingDto toRating(WorkRecord record) {
        if (record.ratingValue() == null) {
            return null;
        }
        return new SourceRatingDto(record.ratingValue(), record.ratingScale(), record.ratingSource());
    }

    private List<String> parseTags(String tagsJson) {
        if (tagsJson == null) {
            return null;
        }
        try {
            List<String> tags = objectMapper.readValue(tagsJson, TAG_LIST);
            return tags.isEmpty() ? List.of() : tags;
        } catch (Exception ex) {
            log.warn("tags 字段不是合法 JSON，按未提供处理：{}", ex.getMessage());
            return null;
        }
    }

    private static String normalizeType(String typeParam) {
        if (typeParam == null || typeParam.isBlank()) {
            return null;
        }
        String value = typeParam.trim();
        if (!WorkType.isValid(value)) {
            // 契约 6.1：参数取值非法属于请求错误（与"没有结果"区分开）。
            throw ApiException.badRequest("type 取值非法：" + value);
        }
        return value;
    }

    private static String normalizeKeyword(String qParam) {
        if (qParam == null) {
            return null;
        }
        String keyword = qParam.trim();
        if (keyword.isEmpty()) {
            return null;
        }
        return keyword.length() > MAX_QUERY_LENGTH ? keyword.substring(0, MAX_QUERY_LENGTH) : keyword;
    }
}

package com.otaku.work;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.common.ApiException;
import com.otaku.common.LikePattern;
import com.otaku.common.PageResponse;
import com.otaku.config.PublicUrlResolver;
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

    public PageResponse<WorkSummaryDto> list(String typeParam, String qParam, int page, int pageSize) {
        String workType = normalizeType(typeParam);
        String keyword = normalizeKeyword(qParam);

        int safePage = Math.max(page, 1);
        int safeSize = pageSize <= 0 ? DEFAULT_PAGE_SIZE : Math.min(pageSize, MAX_PAGE_SIZE);
        String pattern = keyword == null ? null : LikePattern.contains(keyword);

        long total = repository.count(workType, pattern);
        List<WorkSummaryDto> items = total == 0
                ? List.of()
                : repository.findPage(workType, pattern, safeSize, (safePage - 1) * safeSize)
                        .stream()
                        .map(this::toSummary)
                        .toList();
        return PageResponse.of(safePage, safeSize, total, items);
    }

    public WorkDto detail(String workId) {
        if (workId == null || workId.isBlank() || workId.length() > MAX_WORK_ID_LENGTH) {
            // 契约 6.2：格式非法同样返回 404，不用 400 区分"存在与否"。
            throw ApiException.workNotFound();
        }
        WorkRecord record = repository.findByWorkId(workId.trim())
                .orElseThrow(ApiException::workNotFound);
        return new WorkDto(
                record.workId(),
                record.workType(),
                record.title(),
                record.summary(),
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

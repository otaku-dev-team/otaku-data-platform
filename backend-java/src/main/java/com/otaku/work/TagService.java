package com.otaku.work;

import com.otaku.common.ApiException;
import com.otaku.work.dto.TagDtos;
import org.springframework.stereotype.Service;

import java.util.List;

/**
 * 标签词表（{@code GET /api/tags}，Issue #208）。
 *
 * <p>只做两件事：校验 {@code type}、把 {@code limit} 收进上限。
 * 不加缓存：词表查询走覆盖索引，500 条量级的成本远低于引入一份需要失效的缓存
 * （导入结束才变，但缓存失效的代码比查询本身更贵）。
 */
@Service
public class TagService {

    /** 与首站一致的上限；不传即"全部"，这个词表规模下 2000 实际等于全部。 */
    static final int MAX_LIMIT = 2000;

    private final TagRepository repository;

    public TagService(TagRepository repository) {
        this.repository = repository;
    }

    public TagDtos.TagList list(String typeParam, Integer limitParam) {
        String type = normalizeType(typeParam);
        // limit <= 0 视为未传：契约里"省略返回全部"，不把 0 解释成"要 0 条"
        int limit = limitParam == null || limitParam <= 0
                ? MAX_LIMIT
                : Math.min(limitParam, MAX_LIMIT);
        List<TagDtos.TagItem> items = repository.top(type, limit);
        // total 是本次返回条数，不是词表总数——契约与首站同义
        return new TagDtos.TagList(type, items.size(), items);
    }

    private static String normalizeType(String typeParam) {
        if (typeParam == null || typeParam.isBlank()) {
            return null;
        }
        String value = typeParam.trim();
        if (!WorkType.isValid(value)) {
            throw ApiException.badRequest("type 取值非法：" + value);
        }
        return value;
    }
}

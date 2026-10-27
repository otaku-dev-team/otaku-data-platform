package com.otaku.work;

import com.otaku.common.ApiException;
import com.otaku.work.dto.TagDtos;
import org.springframework.stereotype.Service;

import java.util.List;

/**
 * 标签词表（{@code GET /api/tags}，Issue #208）。
 *
 * <p>只做两件事：校验 {@code type}、把 {@code limit} 收进上限。
 *
 * <p>词表查询本身是「分组计数 + 按计数倒序」，**没有索引能消除这次聚合**：
 * 实测 46,273 部作品（222,060 行 {@code work_tag}）时单次 140 ms，
 * 与数据量成正比（全量约 1.7 s）。所以结果进 {@link TagCache}，
 * 由导入结束时整体失效——这是首版没做、上线后按实测补上的。
 */
@Service
public class TagService {

    /** 与首站一致的上限。超过它的请求按它截断（不是报错）。 */
    static final int MAX_LIMIT = 2000;

    private final TagRepository repository;
    private final TagCache cache;

    public TagService(TagRepository repository, TagCache cache) {
        this.repository = repository;
        this.cache = cache;
    }

    public TagDtos.TagList list(String typeParam, Integer limitParam) {
        String type = normalizeType(typeParam);
        // limit <= 0 视为未传：契约里"省略返回全部"，不把 0 解释成"要 0 条"
        int limit = limitParam == null || limitParam <= 0
                ? MAX_LIMIT
                : Math.min(limitParam, MAX_LIMIT);

        // 缓存里是「前 MAX_LIMIT 条」——接口最多只能返回这么多，所以这一份对任何 limit 都够用
        List<TagDtos.TagItem> all = cache.get(type);
        if (all == null) {
            // 双重检查：导入期间每批都会失效，若此时有多个请求同时进来，
            // 没有这层锁每个都会去跑那条全表聚合（全量约 1.7 s）。
            // 命中路径不加锁——它只做一次 get。
            synchronized (cache) {
                all = cache.get(type);
                if (all == null) {
                    all = repository.top(type, MAX_LIMIT);
                    cache.put(type, all);
                }
            }
        }
        List<TagDtos.TagItem> items = all.size() <= limit ? all : all.subList(0, limit);
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

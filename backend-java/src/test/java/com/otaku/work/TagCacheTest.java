package com.otaku.work;

import com.otaku.common.ApiException;
import com.otaku.work.dto.TagDtos;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 标签词表缓存的行为（`GET /api/tags`）。
 *
 * <p>为什么值得单测：词表那条 {@code GROUP BY tag ORDER BY COUNT(*) DESC} 用不上索引，
 * 成本与 {@code work_tag} 行数成正比（46,273 部作品时 140 ms，全量约 1.7 s）。
 * 缓存对了才省得下来，缓存错了会让**客户端看到不存在的标签 / 看不到刚导入的标签**——比慢更糟。
 * 所以钉三条：同样条件只查一次、不同 type 各存各的、失效之后必须重查。
 */
class TagCacheTest {

    private final TagRepository repository = mock(TagRepository.class);
    private final TagCache cache = new TagCache();
    private final TagService service = new TagService(repository, cache);

    private static List<TagDtos.TagItem> tags(int count) {
        return java.util.stream.IntStream.range(0, count)
                .mapToObj(i -> new TagDtos.TagItem("t" + i, 100L - i))
                .toList();
    }

    @Test
    @DisplayName("同样的 type 重复请求：只查一次库")
    void sameTypeQueriesOnce() {
        when(repository.top(any(), anyInt())).thenReturn(tags(3));

        service.list(null, null);
        service.list(null, null);
        service.list(null, 2);

        // limit 不同也共用同一份缓存——缓存存的是「前 MAX_LIMIT 条」整份
        verify(repository, times(1)).top(any(), eq(TagService.MAX_LIMIT));
    }

    @Test
    @DisplayName("不同 type 各存各的，互不串味")
    void differentTypesAreCachedSeparately() {
        when(repository.top(eq("anime"), anyInt())).thenReturn(tags(2));
        when(repository.top(eq("comic"), anyInt())).thenReturn(tags(5));

        assertThat(service.list("anime", null).items()).hasSize(2);
        assertThat(service.list("comic", null).items()).hasSize(5);
        assertThat(service.list("anime", null).items()).hasSize(2);

        verify(repository, times(1)).top(eq("anime"), anyInt());
        verify(repository, times(1)).top(eq("comic"), anyInt());
    }

    @Test
    @DisplayName("失效之后必须重查：否则导入进来的新标签永远看不到")
    void invalidateForcesReload() {
        when(repository.top(any(), anyInt())).thenReturn(tags(2));
        assertThat(service.list(null, null).items()).hasSize(2);

        cache.invalidateAll();
        when(repository.top(any(), anyInt())).thenReturn(tags(4));

        assertThat(service.list(null, null).items()).hasSize(4);
        verify(repository, times(2)).top(any(), anyInt());
    }

    @Test
    @DisplayName("limit 只截断，不重新查库；total 是返回条数")
    void limitTruncatesWithoutQuery() {
        when(repository.top(any(), anyInt())).thenReturn(tags(10));

        TagDtos.TagList first = service.list(null, 3);
        TagDtos.TagList second = service.list(null, 7);

        assertThat(first.items()).hasSize(3);
        assertThat(first.total()).isEqualTo(3);
        assertThat(second.items()).hasSize(7);
        assertThat(second.total()).isEqualTo(7);
        verify(repository, times(1)).top(any(), anyInt());
    }

    @Test
    @DisplayName("limit <= 0 视为未传（不是「要 0 条」），超过上限按上限截断")
    void limitBoundaries() {
        when(repository.top(any(), anyInt())).thenReturn(tags(5));

        assertThat(service.list(null, 0).items()).hasSize(5);
        assertThat(service.list(null, -1).items()).hasSize(5);
        // 上限 2000，但只有 5 条，结论是「全给」
        assertThat(service.list(null, 99999).items()).hasSize(5);
        verify(repository, never()).top(any(), eq(0));
    }

    @Test
    @DisplayName("非法 type 在查库之前就拒掉")
    void invalidTypeRejectedBeforeQuery() {
        assertThatThrownBy(() -> service.list("movie", null))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("type");
        verify(repository, never()).top(any(), anyInt());
    }
}

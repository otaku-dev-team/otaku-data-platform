package com.otaku.work;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.config.PublicUrlResolver;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.List;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 列表总数缓存的行为。
 *
 * <p>为什么值得单测：{@code COUNT(*)} 是 76–126 ms，而取一页只要 0.4 ms
 * （`docs/list-pagination-perf.md`）。缓存对了能省掉每页 100 ms 左右，缓存错了会让
 * **列表条数与实际不符**——这比慢更糟。所以三条边界必须钉住：
 * 同样的筛选只查一次、不同筛选各查各的、导入之后必须重查。
 */
class WorkCountCacheTest {

    private final WorkRepository repository = mock(WorkRepository.class);
    private final CountCache cache = new CountCache();
    private final WorkService service = new WorkService(
            repository, mock(PublicUrlResolver.class), new ObjectMapper(), cache,
            mock(WorkRelationRepository.class),
            // 空快照 = 全部走 AdultTags 的代码默认值，与线上「没改过配置」同一个状态
            new com.otaku.common.AdultPolicy(() -> new com.otaku.appconfig.AppConfigService.Snapshot(0, java.util.Map.of())));

    private void stubCount(long total) {
        when(repository.count(any(), any(), any(), any(), any())).thenReturn(total);
        when(repository.findPage(any(), any(), any(), any(), any(), any(), anyInt(), anyInt()))
                .thenReturn(List.of());
    }

    @Test
    @DisplayName("同一组筛选重复请求：COUNT 只查一次")
    void sameFilterCountsOnce() {
        stubCount(5);

        service.list(null, null, null, null, null, null, null, 1, 20);
        service.list(null, null, null, null, null, null, null, 2, 20);
        service.list(null, null, null, null, "rating", null, null, 3, 20);

        verify(repository, times(1)).count(any(), any(), any(), any(), any());
    }

    @Test
    @DisplayName("筛选不同就必须各查各的——缓存键要把 type/q/tag/min_rating 全带上")
    void differentFiltersAreSeparateEntries() {
        stubCount(5);

        service.list("anime", null, null, null, null, null, null, 1, 20);
        service.list("comic", null, null, null, null, null, null, 1, 20);
        service.list("anime", "魔法", null, null, null, null, null, 1, 20);
        service.list("anime", null, "日常", null, null, null, null, 1, 20);
        service.list("anime", null, null, null, null, "7.5", null, 1, 20);

        verify(repository, times(5)).count(any(), any(), any(), any(), any());
    }

    @Test
    @DisplayName("年份不同也是不同条目——漏了 year 会把 A 年的总数串给 B 年")
    void yearIsPartOfCacheKey() {
        stubCount(5);

        service.list(null, null, null, null, null, null, "2022", 1, 20);
        service.list(null, null, null, null, null, null, "2021", 1, 20);
        service.list(null, null, null, null, null, null, null, 1, 20);

        // 三次都是不同的 year（两个年份 + 不过滤），必须各查各的。
        // 若 CountCache.key 漏了 year，这里只会剩 1 次调用，
        // 用户看到的就是「点 2021 显示 2022 的总数」。
        verify(repository, times(3)).count(any(), any(), any(), any(), any());
    }

    @Test
    @DisplayName("导入失效后必须重新 COUNT，不能拿旧总数糊弄")
    void invalidationForcesRecount() {
        stubCount(5);
        service.list(null, null, null, null, null, null, null, 1, 20);
        verify(repository, times(1)).count(any(), any(), any(), any(), any());

        cache.invalidateAll();

        service.list(null, null, null, null, null, null, null, 1, 20);
        verify(repository, times(2)).count(any(), any(), any(), any(), any());
    }

    @Test
    @DisplayName("键空间不设上限会把内存吃满：超过 256 条要按 LRU 淘汰")
    void cacheIsBounded() {
        for (int i = 0; i < CountCache.MAX_ENTRIES + 50; i++) {
            cache.put("q" + i, i);
        }

        org.assertj.core.api.Assertions.assertThat(cache.size())
                .as("条目数不能超过上限")
                .isEqualTo(CountCache.MAX_ENTRIES);
    }
}

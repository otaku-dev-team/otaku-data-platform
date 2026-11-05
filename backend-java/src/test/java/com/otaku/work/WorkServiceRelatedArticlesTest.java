package com.otaku.work;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.appconfig.AppConfigService;
import com.otaku.article.ArticleService;
import com.otaku.article.dto.ArticleDtos.ArticlePage;
import com.otaku.article.dto.ArticleDtos.ArticleSummary;
import com.otaku.common.AdultPolicy;
import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import com.otaku.config.PublicUrlResolver;
import com.otaku.work.dto.WorkSummaryDto;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

/**
 * 作品→资讯（#409）在作品侧的接线。
 *
 * <p>要守住的是「问谁要资讯」这件事：只有 {@code source='bangumi'} 的作品，
 * 它的 {@code source_id} 才和 {@code related_work_ids} 是同一套号。其它来源
 * （首站自己的 {@code otaku_site} 存量行）拿 source_id 去匹配等于撞号——
 * 不报错、只是把别人的资讯挂上来，所以这里必须显式传 null 而不是「顺手也查一下」。
 */
@ExtendWith(MockitoExtension.class)
class WorkServiceRelatedArticlesTest {

    private static final LocalDateTime NOW = LocalDateTime.of(2026, 11, 1, 8, 0);

    @Mock
    private WorkRepository repository;

    @Mock
    private ArticleService articleService;

    private WorkService service;

    @BeforeEach
    void setUp() {
        service = new WorkService(repository, new PublicUrlResolver(new com.otaku.config.AppProperties()), new ObjectMapper(),
                new CountCache(),
                new WorkRelationRepository(
                        org.mockito.Mockito.mock(
                                org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate.class),
                        org.mockito.Mockito.mock(org.springframework.jdbc.core.JdbcTemplate.class)),
                new AdultPolicy(() -> new AppConfigService.Snapshot(0, Map.of())),
                articleService);
    }

    @Test
    @DisplayName("bangumi 作品：用 source_id 反查，分页参数原样透传")
    void quenchesBySourceIdForBangumiWork() {
        when(repository.findByWorkId("W-1")).thenReturn(Optional.of(
                work("W-1", "bangumi", "11972")));
        ArticlePage expected = new ArticlePage(1, 1, 20, 1, List.of(new ArticleSummary(
                "A-1", "标题", null, "动画", "2026-11-01T08:00:00Z", "首站",
                null, null, List.of())));
        when(articleService.listForWorkSubject("11972", 3, 20)).thenReturn(expected);

        ArticlePage page = service.relatedArticles("W-1", 3, 20);

        assertThat(page).isSameAs(expected);
        verify(articleService).listForWorkSubject("11972", 3, 20);
    }

    @Test
    @DisplayName("非 bangumi 作品不查资讯：source_id 是另一套号，拿去匹配只会撞号")
    void doesNotQueryForNonBangumiWork() {
        when(repository.findByWorkId("W-2")).thenReturn(Optional.of(
                work("W-2", "otaku_site", "11972")));
        when(articleService.listForWorkSubject(null, 1, 20))
                .thenReturn(new ArticlePage(0, 1, 20, 0, List.of()));

        ArticlePage page = service.relatedArticles("W-2", 1, 20);

        assertThat(page.items()).isEmpty();
        verify(articleService).listForWorkSubject(null, 1, 20);
    }

    @Test
    @DisplayName("作品不存在仍是 404，与详情、同标签推荐一致")
    void missingWorkIsNotFound() {        when(repository.findByWorkId("W-404")).thenReturn(Optional.empty());

        assertThatThrownBy(() -> service.relatedArticles("W-404", 1, 20))
                .isInstanceOf(ApiException.class)
                .satisfies(ex -> assertThat(((ApiException) ex).code())
                        .isEqualTo(ErrorCode.WORK_NOT_FOUND));
        verifyNoInteractions(articleService);
    }

    @Test
    @DisplayName("资讯→作品：按入参顺序返回，不按库里的顺序——来源站编辑排的位次是内容的一部分")
    void preservesRequestedOrder() {
        when(repository.findBySourceIds(eq("bangumi"), anyList())).thenReturn(List.of(
                work(2L, "W-2", "bangumi", "8899"),
                work(1L, "W-1", "bangumi", "11972")));

        List<WorkSummaryDto> summaries = service.summariesBySubjectIds(List.of("11972", "8899"));

        assertThat(summaries).extracting(WorkSummaryDto::workId).containsExactly("W-1", "W-2");
    }

    @Test
    @DisplayName("资讯→作品：解析不到的 id 直接跳过（下架/成人/未收录都在仓储侧滤掉了）")
    void skipsUnresolvedIds() {
        when(repository.findBySourceIds(eq("bangumi"), anyList())).thenReturn(List.of(
                work(1L, "W-1", "bangumi", "11972")));

        List<WorkSummaryDto> summaries = service.summariesBySubjectIds(
                List.of("11972", "9799999", " "));

        assertThat(summaries).extracting(WorkSummaryDto::workId).containsExactly("W-1");
    }

    @Test
    @DisplayName("资讯→作品：重复 id 只查一次、只出一次；空入参不查库")
    void dedupesAndShortCircuits() {
        when(repository.findBySourceIds(eq("bangumi"), anyList())).thenReturn(List.of(
                work(1L, "W-1", "bangumi", "11972")));

        assertThat(service.summariesBySubjectIds(List.of("11972", " 11972 ")))
                .extracting(WorkSummaryDto::workId).containsExactly("W-1");
        verify(repository, org.mockito.Mockito.times(1)).findBySourceIds(eq("bangumi"), anyList());

        assertThat(service.summariesBySubjectIds(List.of())).isEmpty();
        assertThat(service.summariesBySubjectIds(null)).isEmpty();
    }

    @Test
    @DisplayName("资讯→作品：入参最多取 30 个，防一条脏数据把 IN 撑爆")
    void capsIdCount() {
        when(repository.findBySourceIds(eq("bangumi"), anyList())).thenReturn(List.of());

        List<String> many = java.util.stream.IntStream.rangeClosed(1, 40)
                .mapToObj(i -> String.valueOf(10000 + i)).toList();
        service.summariesBySubjectIds(many);

        org.mockito.ArgumentCaptor<List<String>> captor =
                org.mockito.ArgumentCaptor.forClass(List.class);
        verify(repository).findBySourceIds(eq("bangumi"), captor.capture());
        assertThat(captor.getValue()).hasSize(30);
    }

    private static WorkRecord work(String workId, String source, String sourceId) {
        return work(1L, workId, source, sourceId);
    }

    private static WorkRecord work(long id, String workId, String source, String sourceId) {
        return new WorkRecord(
                id, workId, "anime", "标题", null, 2022,
                null, null, null, null,
                null, null, null,
                "[\"科幻\"]",
                new BigDecimal("7.80"), "0-10", "otaku_site",
                5000,
                source, sourceId, null,
                NOW, NOW, null);
    }
}

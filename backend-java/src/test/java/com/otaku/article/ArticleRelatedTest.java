package com.otaku.article;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.article.dto.ArticleDtos;
import com.otaku.common.AdultPolicy;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.time.LocalDateTime;
import java.util.List;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 资讯↔资讯的排序与召回（#414）。
 *
 * <p>断言的是**关系**：共享两个标签的排在共享一个的前面、同分看时间、没有共同点时
 * 不靠「同来源」凑数、limit 夹取。具体分数不是契约。
 */
class ArticleRelatedTest {

    private ArticleRepository repository;
    private ArticleService service;

    @BeforeEach
    void setUp() {
        repository = mock(ArticleRepository.class);
        AdultPolicy adultPolicy = mock(AdultPolicy.class);
        when(adultPolicy.strip(any())).thenAnswer(inv -> inv.getArgument(0));
        service = new ArticleService(repository, new ObjectMapper(), adultPolicy,
                mock(ArticleRelatedIdsSemantics.class));
    }

    @Test
    @DisplayName("源资讯不存在 → null（控制器转 404）")
    void missingSourceReturnsNull() {
        when(repository.findByArticleId("A-x")).thenReturn(Optional.empty());

        assertThat(service.related("A-x", 10)).isNull();
        verify(repository, never()).findRelatedCandidates(anyString(), any(), any(), anyInt());
    }

    @Test
    @DisplayName("源资讯既无标签也无分类 → 空列表，不去查库")
    void noTagsNoCategoryGivesEmpty() {
        when(repository.findByArticleId("A-1"))
                .thenReturn(Optional.of(article("A-1", null, null, "2026-11-01T00:00:00")));

        var result = service.related("A-1", 10);

        assertThat(result.items()).isEmpty();
        verify(repository, never()).findRelatedCandidates(anyString(), any(), any(), anyInt());
    }

    @Test
    @DisplayName("共享标签多的排前面；同分时新的排前面")
    void moreSharedTagsRankFirst() {
        when(repository.findByArticleId("A-1"))
                .thenReturn(Optional.of(article("A-1", "动画", "[\"机战\",\"科幻\",\"原创\"]",
                        "2026-11-01T00:00:00")));
        when(repository.findRelatedCandidates(eq("A-1"), anyString(), eq("动画"), anyInt()))
                .thenReturn(List.of(
                        article("A-2", "动画", "[\"机战\"]", "2026-11-05T00:00:00"),      // 1 个共享
                        article("A-3", "动画", "[\"机战\",\"科幻\"]", "2026-11-03T00:00:00"), // 2 个共享
                        article("A-4", "动画", "[\"机战\",\"科幻\"]", "2026-11-04T00:00:00")));

        var items = service.related("A-1", 10).items();

        assertThat(items).extracting(ArticleDtos.ArticleSummary::articleId)
                .containsExactly("A-4", "A-3", "A-2");
    }

    @Test
    @DisplayName("没有共同标签、但同分类的仍然入选，排在共享标签之后")
    void sameCategoryIsWeakerSignal() {
        when(repository.findByArticleId("A-1"))
                .thenReturn(Optional.of(article("A-1", "动画", "[\"机战\"]", "2026-11-01T00:00:00")));
        when(repository.findRelatedCandidates(anyString(), anyString(), eq("动画"), anyInt()))
                .thenReturn(List.of(
                        article("A-cat", "动画", "[\"其他\"]", "2026-11-06T00:00:00"),
                        article("A-tag", "动画", "[\"机战\"]", "2026-11-02T00:00:00")));

        var items = service.related("A-1", 10).items();

        assertThat(items).extracting(ArticleDtos.ArticleSummary::articleId)
                .containsExactly("A-tag", "A-cat");
    }

    @Test
    @DisplayName("limit 缺省 10、上限 20、小于 1 按 10")
    void limitIsClamped() {
        when(repository.findByArticleId("A-1"))
                .thenReturn(Optional.of(article("A-1", "动画", "[\"机战\"]", "2026-11-01T00:00:00")));
        when(repository.findRelatedCandidates(anyString(), anyString(), eq("动画"), anyInt()))
                .thenReturn(List.of(article("A-2", "动画", "[\"机战\"]", "2026-11-02T00:00:00")));

        assertThat(service.related("A-1", 0).items()).hasSize(1);
        assertThat(service.related("A-1", 999).items()).hasSize(1);
        // 候选查询用 limit * 5，上限 20 → 100
        verify(repository).findRelatedCandidates("A-1", "[\"机战\"]", "动画", 100);
    }

    @Test
    @DisplayName("候选里只有同来源、没有共同标签和分类时，不靠「同来源」凑数")
    void sameSourceAloneIsNotEnough() {
        when(repository.findByArticleId("A-1"))
                .thenReturn(Optional.of(article("A-1", "动画", "[\"机战\"]", "2026-11-01T00:00:00")));
        // 仓储按「标签重叠 OR 同分类」召回，这条只可能来自标签/分类；
        // 这里构造一个标签其实是别的、分类也不同的候选，验证打分后会被丢掉。
        when(repository.findRelatedCandidates(anyString(), anyString(), eq("动画"), anyInt()))
                .thenReturn(List.of(article("A-other", "漫画", "[\"恋爱\"]", "2026-11-02T00:00:00")));

        assertThat(service.related("A-1", 10).items()).isEmpty();
    }

    private static ArticleRecord article(String articleId, String category, String tagsJson,
                                         String publishedAt) {
        return new ArticleRecord(
                1L, articleId, "otaku_site", articleId, "标题 " + articleId, null, null,
                category, LocalDateTime.parse(publishedAt), "来源站", null, null,
                tagsJson, null, LocalDateTime.parse("2026-11-01T00:00:00"),
                LocalDateTime.parse("2026-11-01T00:00:00"));
    }
}

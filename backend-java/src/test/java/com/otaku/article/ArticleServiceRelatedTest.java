package com.otaku.article;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.appconfig.AppConfigService;
import com.otaku.article.dto.ArticleDtos.ArticlePage;
import com.otaku.common.AdultPolicy;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 作品→资讯（#409）的服务层行为。
 *
 * <p>这层要钉的是**「什么时候宁可不查」**：{@code related_work_ids} 里那串数字可能是
 * content_id，也可能是 subject id，两者从值上分不出来。语义没切就返回空——
 * 猜错不会报错，只会把别的作品的资讯挂到这部作品下面。
 *
 * <p>SQL 本身由 {@link ArticleRepositorySqlTest} 钉，真库行为由
 * {@code WorkArticlesIntegrationTest} 兜底，这里只管分支与参数。
 */
@ExtendWith(MockitoExtension.class)
class ArticleServiceRelatedTest {

    private static final String SUBJECT_ID = "11972";

    @Mock
    private ArticleRepository repository;

    private ArticleService serviceWithSemantics(String semantic) {
        AdultPolicy adultPolicy = new AdultPolicy(
                () -> new AppConfigService.Snapshot(0, Map.of()));
        ArticleRelatedIdsSemantics semantics = new ArticleRelatedIdsSemantics(
                () -> semantic == null
                        ? new AppConfigService.Snapshot(0, Map.of())
                        : new AppConfigService.Snapshot(1, Map.of(
                                ArticleRelatedIdsSemantics.KEY,
                                new ObjectMapper().getNodeFactory().textNode(semantic))));
        return new ArticleService(repository, new ObjectMapper(), adultPolicy, semantics);
    }

    @Test
    @DisplayName("语义没切（默认）：返回 200 + 空页，一条都不查——宁可空，不要撞号")
    void returnsEmptyWhenSemanticsNotSwitched() {
        ArticlePage page = serviceWithSemantics(null).listForWorkSubject(SUBJECT_ID, 1, 20);

        assertThat(page.total()).isZero();
        assertThat(page.items()).isEmpty();
        assertThat(page.totalPages()).isZero();
        verify(repository, never()).countRelatedToWork(anyString());
        verify(repository, never()).findRelatedToWork(anyString(), anyInt(), anyInt());
    }

    @Test
    @DisplayName("库里的值写成 content_id（显式配置）同样不查")
    void returnsEmptyWhenExplicitlyContentId() {
        ArticlePage page = serviceWithSemantics(ArticleRelatedIdsSemantics.CONTENT_ID)
                .listForWorkSubject(SUBJECT_ID, 1, 20);

        assertThat(page.items()).isEmpty();
        verify(repository, never()).countRelatedToWork(anyString());
    }

    @Test
    @DisplayName("切到 subject_id 后按作品 id 反查，分页参数透传")
    void queriesWhenSwitchedToSubjectId() {
        when(repository.countRelatedToWork(SUBJECT_ID)).thenReturn(21L);
        when(repository.findRelatedToWork(SUBJECT_ID, 20, 20)).thenReturn(List.of(
                record("A-1", "第一篇"),
                record("A-2", "第二篇")));

        ArticlePage page = serviceWithSemantics(ArticleRelatedIdsSemantics.SUBJECT_ID)
                .listForWorkSubject(SUBJECT_ID, 2, 20);

        assertThat(page.total()).isEqualTo(21);
        assertThat(page.page()).isEqualTo(2);
        assertThat(page.totalPages()).isEqualTo(2);
        assertThat(page.items()).extracting("articleId").containsExactly("A-1", "A-2");
        assertThat(page.items().get(0).publishedAt()).isEqualTo("2026-11-01T08:00Z");
    }

    @Test
    @DisplayName("没有 subject id（非 bangumi 作品）不查库：拿别的号段去匹配只会撞号")
    void skipsQueryWithoutSubjectId() {
        ArticlePage page = serviceWithSemantics(ArticleRelatedIdsSemantics.SUBJECT_ID)
                .listForWorkSubject(null, 1, 20);

        assertThat(page.items()).isEmpty();
        verify(repository, never()).findRelatedToWork(anyString(), anyInt(), anyInt());
    }

    @Test
    @DisplayName("page_size 超限按 50 截断、page 小于 1 按 1：与资讯列表同口径")
    void clampsPaging() {
        when(repository.countRelatedToWork(SUBJECT_ID)).thenReturn(0L);

        ArticlePage page = serviceWithSemantics(ArticleRelatedIdsSemantics.SUBJECT_ID)
                .listForWorkSubject(SUBJECT_ID, 0, 999);

        assertThat(page.page()).isEqualTo(1);
        assertThat(page.pageSize()).isEqualTo(50);
    }

    private static ArticleRecord record(String articleId, String title) {
        LocalDateTime published = LocalDateTime.of(2026, 11, 1, 8, 0);
        return new ArticleRecord(1L, articleId, "otaku_site", "9001", title, "摘要", "正文",
                "动画", published, "首站", "https://example.com/a", null,
                "[\"资讯标签\"]", "[\"11972\"]", published, published);
    }
}

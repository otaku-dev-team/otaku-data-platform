package com.otaku.article;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.appconfig.AppConfigService;
import com.otaku.article.dto.ArticleDtos.ArticleDetail;
import com.otaku.work.WorkService;
import com.otaku.work.dto.WorkSummaryDto;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

/**
 * 资讯详情里「关联作品」的拼装（#408）。
 *
 * <p>要钉的是一条区分：{@code null}（没切语义、不解析）vs {@code []}（切了但没可用作品）。
 * 客户端对两者展示一致，但契约上它们是两件事——写反了以后排查「为什么这块一直空」
 * 会找不到出口。
 */
@ExtendWith(MockitoExtension.class)
class ArticleDetailAssemblerTest {

    @Mock
    private ArticleService articleService;

    @Mock
    private WorkService workService;

    private ArticleDetailAssembler assembler(String semantic) {
        ArticleRelatedIdsSemantics semantics = new ArticleRelatedIdsSemantics(
                () -> semantic == null
                        ? new AppConfigService.Snapshot(0, Map.of())
                        : new AppConfigService.Snapshot(1, Map.of(
                                ArticleRelatedIdsSemantics.KEY,
                                new ObjectMapper().getNodeFactory().textNode(semantic))));
        return new ArticleDetailAssembler(articleService, workService, semantics);
    }

    @Test
    @DisplayName("语义没切：related_works 保持 null，不查作品表")
    void keepsNullWhenSemanticsOff() {
        when(articleService.detail("A-1")).thenReturn(detail(List.of("11972")));

        ArticleDetail result = assembler(null).detail("A-1");

        assertThat(result.relatedWorks()).isNull();
        verifyNoInteractions(workService);
    }

    @Test
    @DisplayName("切了语义且有 id：按 id 解析并填进 related_works")
    void resolvesWhenSemanticsOn() {
        when(articleService.detail("A-1")).thenReturn(detail(List.of("11972", "8899")));
        List<WorkSummaryDto> works = List.of(summary("W-1"), summary("W-2"));
        when(workService.summariesBySubjectIds(List.of("11972", "8899"))).thenReturn(works);

        ArticleDetail result = assembler(ArticleRelatedIdsSemantics.SUBJECT_ID).detail("A-1");

        assertThat(result.relatedWorks()).isSameAs(works);
        assertThat(result.relatedWorkIds()).containsExactly("11972", "8899");
    }

    @Test
    @DisplayName("切了语义但这篇没关联作品：给 [] 而不是 null（「解析过，确实没有」）")
    void emptyListWhenNoRelatedIds() {
        when(articleService.detail("A-1")).thenReturn(detail(List.of()));

        ArticleDetail result = assembler(ArticleRelatedIdsSemantics.SUBJECT_ID).detail("A-1");

        assertThat(result.relatedWorks()).isNotNull().isEmpty();
        verify(workService, never()).summariesBySubjectIds(anyList());
    }

    @Test
    @DisplayName("资讯不存在返回 null，由控制器转 404")
    void missingArticle() {
        when(articleService.detail("A-404")).thenReturn(null);

        assertThat(assembler(ArticleRelatedIdsSemantics.SUBJECT_ID).detail("A-404")).isNull();
        verifyNoInteractions(workService);
    }

    private static ArticleDetail detail(List<String> relatedWorkIds) {
        return new ArticleDetail("A-1", "标题", "摘要", "正文", "动画",
                "2026-10-01T08:00:00Z", "首站", null, null, List.of(), relatedWorkIds, null);
    }

    private static WorkSummaryDto summary(String workId) {
        return new WorkSummaryDto(workId, "anime", "作品 " + workId, 2022,
                null, List.of(), null, "bangumi");
    }
}

package com.otaku.article;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import com.otaku.common.PublicIdGenerator;
import com.otaku.importer.ImportBatchRepository;
import com.otaku.importer.dto.ImportBatchResult;
import com.otaku.importer.dto.ImportItemResult;
import com.otaku.article.dto.ArticleImportRequest;
import com.otaku.article.dto.ArticleImportRequest.ArticleImportItem;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.transaction.support.TransactionCallback;
import org.springframework.transaction.support.TransactionTemplate;

import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 资讯导入的服务层行为。
 *
 * <p>与作品/档期导入的测试同一口径：不连数据库，只钉住「参数怎么解释、
 * 边界怎么处理、幂等是否正确」这类容易回归的逻辑。SQL 正确性由迁移与
 * 真实库实测兜底。
 */
@ExtendWith(MockitoExtension.class)
class ArticleImportServiceTest {

    @Mock
    private ArticleRepository articleRepository;

    @Mock
    private ImportBatchRepository batchRepository;

    @Mock
    private PublicIdGenerator idGenerator;

    @Mock
    private TransactionTemplate transactionTemplate;

    private ArticleImportService service;

    @BeforeEach
    void setUp() {
        service = new ArticleImportService(articleRepository, batchRepository,
                idGenerator, transactionTemplate, new ObjectMapper());
        // 事务模板在测试里直接执行回调，不起真事务。
        // lenient：拒收类用例（校验失败、批次过大）根本走不到事务，
        // strict stubs 会把「没用到」当失败报出来，那是测试基建而不是行为问题。
        org.mockito.Mockito.lenient()
                .when(transactionTemplate.execute(any())).thenAnswer(invocation -> {
            TransactionCallback<?> callback = invocation.getArgument(0);
            return callback.doInTransaction(null);
        });
        org.mockito.Mockito.lenient()
                .when(batchRepository.saveAndRecordRun(any(), anyString(), anyString())).thenReturn(1);
    }

    private static ArticleImportItem item(String sourceId, String title, List<String> tags) {
        return new ArticleImportItem(
                sourceId, title, "摘要 " + sourceId, "正文第一段。\n正文第二段。",
                "漫画", OffsetDateTime.parse("2026-10-22T05:00:00Z"),
                "ラノベニュースオンライン", "https://ln-news.com/articles/127000",
                "http://154.8.194.198:8000/article-images/a.jpg",
                tags, List.of("7267"));
    }

    private static ArticleImportRequest request(ArticleImportItem... items) {
        return new ArticleImportRequest(
                "otaku_site-article-20261022-abc", "otaku_site",
                OffsetDateTime.parse("2026-10-22T19:00:00Z"), List.of(items));
    }

    @Test
    @DisplayName("新条目入库，article_id 带 A- 前缀")
    void inserts() {
        when(idGenerator.nextArticleId()).thenReturn("A-test0001");

        ImportBatchResult result = service.importArticles(request(item("339", "标题 339", List.of("科幻"))));

        assertThat(result.counts().inserted()).isEqualTo(1);
        ArgumentCaptor<ArticleRecord> captor = ArgumentCaptor.forClass(ArticleRecord.class);
        verify(articleRepository).insert(captor.capture());
        ArticleRecord saved = captor.getValue();
        assertThat(saved.articleId()).isEqualTo("A-test0001");
        assertThat(saved.title()).isEqualTo("标题 339");
        assertThat(saved.sourceUrl()).isEqualTo("https://ln-news.com/articles/127000");
        assertThat(saved.tagsJson()).isEqualTo("[\"科幻\"]");
    }

    @Test
    @DisplayName("同内容重跑：unchanged，不写库（重跑应全部 unchanged）")
    void rerunSameContentIsUnchanged() {
        ArticleImportItem same = item("339", "标题 339", List.of("科幻"));
        ArticleRecord existing = new ArticleRecord(
                7L, "A-existing", "otaku_site", "339",
                "标题 339", "摘要 339", "正文第一段。\n正文第二段。", "漫画",
                LocalDateTime.parse("2026-10-22T05:00:00"), "ラノベニュースオンライン",
                "https://ln-news.com/articles/127000",
                "http://154.8.194.198:8000/article-images/a.jpg",
                "[\"科幻\"]", "[\"7267\"]",
                LocalDateTime.parse("2026-10-22T06:00:00"), LocalDateTime.parse("2026-10-22T06:00:00"));
        when(articleRepository.findBySourceKey("otaku_site", "339")).thenReturn(Optional.of(existing));

        ImportBatchResult result = service.importArticles(request(same));

        assertThat(result.counts().unchanged()).isEqualTo(1);
        verify(articleRepository, never()).update(any());
        verify(articleRepository, never()).insert(any());
    }

    @Test
    @DisplayName("摘要变了：updated")
    void changedSummaryUpdates() {
        ArticleImportItem incoming = item("339", "标题 339", List.of("科幻"));
        ArticleRecord existing = new ArticleRecord(
                7L, "A-existing", "otaku_site", "339",
                "标题 339", "旧摘要", "正文第一段。\n正文第二段。", "漫画",
                LocalDateTime.parse("2026-10-22T05:00:00"), "ラノベニュースオンライン",
                "https://ln-news.com/articles/127000",
                "http://154.8.194.198:8000/article-images/a.jpg",
                "[\"科幻\"]", "[\"7267\"]",
                LocalDateTime.parse("2026-10-22T06:00:00"), LocalDateTime.parse("2026-10-22T06:00:00"));
        when(articleRepository.findBySourceKey("otaku_site", "339")).thenReturn(Optional.of(existing));

        ImportBatchResult result = service.importArticles(request(incoming));

        assertThat(result.counts().updated()).isEqualTo(1);
        verify(articleRepository).update(any());
    }

    @Test
    @DisplayName("正文归一成一行一段：HTML 解析出的空行与缩进不该撑出空白")
    void normalizesBodyIntoOneLinePerParagraph() {
        when(idGenerator.nextArticleId()).thenReturn("A-test0002");
        ArticleImportItem messy = new ArticleImportItem(
                "340", "标题 340", null, "第一段\n\n\n\n    第二段\n  \n第三段",
                null, null, null, null, null, null, null);

        service.importArticles(request(messy));

        ArgumentCaptor<ArticleRecord> captor = ArgumentCaptor.forClass(ArticleRecord.class);
        verify(articleRepository).insert(captor.capture());
        assertThat(captor.getValue().body()).isEqualTo("第一段\n第二段\n第三段");
    }

    @Test
    @DisplayName("原文链接格式不对只丢值，不拒收整条（章程 G3：没链接就不给跳转，不是不展示）")
    void dropsInvalidSourceUrlButKeepsArticle() {
        when(idGenerator.nextArticleId()).thenReturn("A-test0003");
        ArticleImportItem badUrl = new ArticleImportItem(
                "341", "标题 341", "摘要", "正文", "动画", null, "来源",
                "javascript:alert(1)", null, null, null);

        ImportBatchResult result = service.importArticles(request(badUrl));

        assertThat(result.counts().inserted()).isEqualTo(1);
        assertThat(result.counts().rejected()).isZero();
        ArgumentCaptor<ArticleRecord> captor = ArgumentCaptor.forClass(ArticleRecord.class);
        verify(articleRepository).insert(captor.capture());
        assertThat(captor.getValue().sourceUrl()).isNull();
    }

    @Test
    @DisplayName("title 缺失：拒收整条")
    void rejectsMissingTitle() {
        ImportBatchResult result = service.importArticles(request(item("342", "  ", List.of())));

        assertThat(result.counts().rejected()).isEqualTo(1);
        assertThat(result.errors()).anyMatch(e -> "TITLE_REQUIRED".equals(e.code()));
        verify(articleRepository, never()).insert(any());
    }

    @Test
    @DisplayName("source_id 缺失：拒收整条")
    void rejectsMissingSourceId() {
        ImportBatchResult result = service.importArticles(request(item(null, "标题", List.of())));

        assertThat(result.counts().rejected()).isEqualTo(1);
        assertThat(result.errors()).anyMatch(e -> "SOURCE_ID_REQUIRED".equals(e.code()));
    }

    @Test
    @DisplayName("同批 source_id 重复：后一条覆盖前一条，并给出提示")
    void duplicateInBatchKeepsLast() {
        when(idGenerator.nextArticleId()).thenReturn("A-test0004");
        // 用一张内存表顶替仓储的查/写：真实运行时第二条会查到刚插入的那条，
        // Mockito 默认每次都返回空 Optional，两条都会走 insert 分支 ——
        // 那样测的就不是「以最后一次为准」，而是「mock 记不住事」了。
        Map<String, ArticleRecord> table = new LinkedHashMap<>();
        when(articleRepository.findBySourceKey(anyString(), anyString()))
                .thenAnswer(inv -> Optional.ofNullable(table.get(inv.getArgument(1, String.class))));
        // insert / update 返回 void，不能用 when()（那是给有返回值的方法用的）
        org.mockito.Mockito.doAnswer(inv -> {
            ArticleRecord record = inv.getArgument(0);
            table.put(record.sourceId(), record);
            return null;
        }).when(articleRepository).insert(any());
        // update 也要写回：第二条走的是更新分支，漏了它表里就永远停在第一版，
        // 断言「以最后一次为准」会得到一个假失败。
        org.mockito.Mockito.doAnswer(inv -> {
            ArticleRecord record = inv.getArgument(0);
            table.put(record.sourceId(), record);
            return null;
        }).when(articleRepository).update(any());

        ArticleImportItem first = item("343", "第一版标题", List.of("科幻"));
        ArticleImportItem second = item("343", "第二版标题", List.of("科幻"));
        ImportBatchResult result = service.importArticles(request(first, second));

        assertThat(result.counts().inserted()).isEqualTo(1);
        assertThat(result.counts().updated()).isEqualTo(1);
        assertThat(result.errors())
                .anyMatch(e -> "DUPLICATE_IN_BATCH".equals(e.code()));
        // 库里最终留的是后一条的标题
        assertThat(table.get("343").title()).isEqualTo("第二版标题");
    }

    @Test
    @DisplayName("批次过大：400 拒收，不逐条处理")
    void rejectsOversizedBatch() {
        ArticleImportItem[] tooMany = new ArticleImportItem[201];
        for (int i = 0; i < tooMany.length; i++) {
            tooMany[i] = item(String.valueOf(1000 + i), "标题 " + i, List.of());
        }
        ArticleImportRequest oversized = new ArticleImportRequest(
                "otaku_site-article-20261022-big", "otaku_site",
                OffsetDateTime.parse("2026-10-22T19:00:00Z"), List.of(tooMany));

        assertThatThrownBy(() -> service.importArticles(oversized))
                .isInstanceOf(ApiException.class)
                .extracting(e -> ((ApiException) e).code())
                .isEqualTo(ErrorCode.BATCH_TOO_LARGE);
        verify(articleRepository, never()).insert(any());
    }

    @Test
    @DisplayName("tags 为空数组：存 []（明确无标签），不是 null")
    void keepsEmptyTagsDistinctFromMissing() {
        when(idGenerator.nextArticleId()).thenReturn("A-test0005");

        service.importArticles(request(item("344", "标题 344", List.of())));

        ArgumentCaptor<ArticleRecord> captor = ArgumentCaptor.forClass(ArticleRecord.class);
        verify(articleRepository).insert(captor.capture());
        assertThat(captor.getValue().tagsJson()).isEqualTo("[]");
    }

    @Test
    @DisplayName("tags 未提供：存 null（不覆盖旧值）")
    void nullTagsStayNull() {
        when(idGenerator.nextArticleId()).thenReturn("A-test0006");

        service.importArticles(request(item("345", "标题 345", null)));

        ArgumentCaptor<ArticleRecord> captor = ArgumentCaptor.forClass(ArticleRecord.class);
        verify(articleRepository).insert(captor.capture());
        assertThat(captor.getValue().tagsJson()).isNull();
    }

    @Test
    @DisplayName("标签去重保序（顺序影响 JSON 文本，抖动会让每次重跑都变 updated）")
    void tagsDeduplicateKeepingOrder() {
        when(idGenerator.nextArticleId()).thenReturn("A-test0007");

        service.importArticles(request(
                item("346", "标题 346", List.of("科幻", "校园", "科幻", " 热血  "))));

        ArgumentCaptor<ArticleRecord> captor = ArgumentCaptor.forClass(ArticleRecord.class);
        verify(articleRepository).insert(captor.capture());
        assertThat(captor.getValue().tagsJson()).isEqualTo("[\"科幻\",\"校园\",\"热血\"]");
    }
}
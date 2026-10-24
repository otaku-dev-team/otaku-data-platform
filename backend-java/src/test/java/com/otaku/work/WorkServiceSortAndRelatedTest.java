package com.otaku.work;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import com.otaku.config.PublicUrlResolver;
import com.otaku.work.dto.RelatedWorksDto;
import com.otaku.work.dto.WorkSummaryDto;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

/**
 * 列表排序参数与详情页推荐的**服务层行为**。
 *
 * <p>不连数据库：SQL 正确性由 `V6` 索引与真实库上的手工实测兜底，这里只钉住
 * 「参数怎么解释、边界怎么处理、有没有意外多查一次」这类容易回归的逻辑。
 */
@ExtendWith(MockitoExtension.class)
class WorkServiceSortAndRelatedTest {

    private static final LocalDateTime NOW = LocalDateTime.parse("2026-10-22T04:00:00");

    @Mock
    private WorkRepository repository;

    @Mock
    private PublicUrlResolver publicUrlResolver;

    private WorkService service;

    @BeforeEach
    void setUp() {
        service = new WorkService(repository, publicUrlResolver, new ObjectMapper());
    }

    @Test
    @DisplayName("sort 透传到仓储，page_size 超限按 50 截断")
    void listPassesSortAndCapsPageSize() {
        when(repository.count(null, null, null, null)).thenReturn(1L);
        when(repository.findPage(any(), any(), any(), eq(WorkSort.RATING), any(), eq(50), eq(0)))
                .thenReturn(List.of(record(1L, "W-1", "[\"科幻\"]")));

        var page = service.list(null, null, null, "rating", null, 1, 999);

        assertThat(page.items()).hasSize(1);
        assertThat(page.pageSize()).isEqualTo(50);
        verify(repository).findPage(null, null, null, WorkSort.RATING, null, 50, 0);
    }

    @Test
    @DisplayName("非法 sort 直接 400，且不碰数据库")
    void invalidSortFailsFast() {
        assertThatThrownBy(() -> service.list(null, null, null, "popular", null, 1, 20))
                .isInstanceOf(ApiException.class)
                .satisfies(ex -> assertThat(((ApiException) ex).code()).isEqualTo(ErrorCode.BAD_REQUEST));

        verifyNoInteractions(repository);
    }

    @Test
    @DisplayName("tag 去掉首尾空白后透传，计数与取页用同一个条件")
    void tagIsTrimmedAndPassedThrough() {
        when(repository.count(null, null, "科幻", null)).thenReturn(1L);
        when(repository.findPage(null, null, "科幻", WorkSort.ID, null, 20, 0))
                .thenReturn(List.of(record(1L, "W-1", "[\"科幻\"]")));

        var page = service.list(null, null, "  科幻  ", null, null, 1, 20);

        assertThat(page.items()).hasSize(1);
        verify(repository).count(null, null, "科幻", null);
        verify(repository).findPage(null, null, "科幻", WorkSort.ID, null, 20, 0);
    }

    @Test
    @DisplayName("空 tag 视为不过滤，不把空串塞进查询")
    void blankTagMeansNoFilter() {
        when(repository.count(null, null, null, null)).thenReturn(0L);

        service.list(null, null, "   ", null, null, 1, 20);

        verify(repository).count(null, null, null, null);
        verify(repository, never()).findPage(any(), any(), any(), any(), any(), anyInt(), anyInt());
    }

    @Test
    @DisplayName("超长 tag 截到 64 字符，与列的宽度和回填脚本一致")
    void tagIsTruncatedToColumnWidth() {
        String longTag = "长".repeat(80);
        when(repository.count(any(), any(), any(), any())).thenReturn(0L);

        service.list(null, null, longTag, null, null, 1, 20);

        ArgumentCaptor<String> captured = ArgumentCaptor.forClass(String.class);
        verify(repository).count(any(), any(), captured.capture(), any());
        assertThat(captured.getValue()).hasSize(64);
    }

    @Test
    @DisplayName("tag 与 type / q / sort 可组合，四个条件一起透传")
    void tagCombinesWithOtherFilters() {
        when(repository.count("anime", "%魔法%", "科幻", null)).thenReturn(1L);
        when(repository.findPage("anime", "%魔法%", "科幻", WorkSort.YEAR, null, 10, 0))
                .thenReturn(List.of(record(1L, "W-1", "[\"科幻\"]")));

        service.list("anime", "魔法", "科幻", "year", null, 1, 10);

        verify(repository).findPage("anime", "%魔法%", "科幻", WorkSort.YEAR, null, 10, 0);
    }

    // ------------------------------------------------------- 榜单 min_rating

    @Test
    @DisplayName("min_rating 解析后同时透传给计数与取页（两处条件必须一致）")
    void minRatingIsPassedToBothCountAndPage() {
        when(repository.count(null, null, null, new BigDecimal("7.0"))).thenReturn(1L);
        when(repository.findPage(null, null, null, WorkSort.RATING, new BigDecimal("7.0"), 20, 0))
                .thenReturn(List.of(record(1L, "W-1", "[\"科幻\"]")));

        service.list(null, null, null, "rating", " 7.0 ", 1, 20);

        verify(repository).count(null, null, null, new BigDecimal("7.0"));
        verify(repository).findPage(null, null, null, WorkSort.RATING, new BigDecimal("7.0"), 20, 0);
    }

    @Test
    @DisplayName("min_rating 省略或空串都表示不过滤，不往 SQL 里塞条件")
    void blankMinRatingMeansNoFilter() {
        when(repository.count(null, null, null, null)).thenReturn(0L);

        service.list(null, null, null, null, null, 1, 20);
        service.list(null, null, null, null, "   ", 1, 20);

        verify(repository, org.mockito.Mockito.times(2)).count(null, null, null, null);
    }

    @Test
    @DisplayName("边界值 0 与 10 合法：0 表示「只要有评分」，10 表示「满分」")
    void minRatingAcceptsBoundaries() {
        when(repository.count(null, null, null, BigDecimal.ZERO)).thenReturn(0L);
        when(repository.count(null, null, null, BigDecimal.TEN)).thenReturn(0L);

        service.list(null, null, null, "rating", "0", 1, 20);
        service.list(null, null, null, "rating", "10", 1, 20);

        verify(repository).count(null, null, null, new BigDecimal("0"));
        verify(repository).count(null, null, null, new BigDecimal("10"));
    }

    @Test
    @DisplayName("min_rating 非法（非数字 / 负数 / 超上限）一律 400，且不碰数据库")
    void invalidMinRatingFailsFast() {
        for (String bad : List.of("abc", "-0.1", "10.01", "NaN")) {
            assertThatThrownBy(() -> service.list(null, null, null, "rating", bad, 1, 20))
                    .as("min_rating=%s 应被拒绝", bad)
                    .isInstanceOf(ApiException.class)
                    .satisfies(ex -> assertThat(((ApiException) ex).code())
                            .isEqualTo(ErrorCode.BAD_REQUEST));
        }

        verifyNoInteractions(repository);
    }

    @Test
    @DisplayName("有标签：回传 basis_tags，并把标签序列化后交给仓储求交集")
    void relatedReturnsBasisTags() {
        when(repository.findByWorkId("W-1")).thenReturn(java.util.Optional.of(
                record(1L, "W-1", "[\"科幻\",\"机战\"]")));
        when(publicUrlResolver.baseUrl()).thenReturn("http://localhost:8080");
        when(repository.findRelated(eq(1L), anyString(), eq(18)))
                .thenReturn(List.of(record(9L, "W-9", "[\"科幻\"]")));

        RelatedWorksDto dto = service.related("W-1", null);

        assertThat(dto.basisTags()).containsExactly("科幻", "机战");
        assertThat(dto.items()).hasSize(1);
        assertThat(dto.items().get(0).workId()).isEqualTo("W-9");
        // 封面地址永远指向本服务，不暴露来源站
        assertThat(dto.items().get(0).coverUrl()).isEqualTo("http://localhost:8080/api/covers/W-9");

        ArgumentCaptor<String> tagsJson = ArgumentCaptor.forClass(String.class);
        // 多取 3 倍给去重用：limit 6 × 3
        verify(repository).findRelated(eq(1L), tagsJson.capture(), eq(18));
        assertThat(tagsJson.getValue()).contains("科幻", "机战");
    }

    @Test
    @DisplayName("limit 省略取 6、超 20 截断、非正数回落到默认")
    void relatedNormalizesLimit() {
        when(repository.findByWorkId(anyString())).thenReturn(java.util.Optional.of(
                record(1L, "W-1", "[\"科幻\"]")));
        when(repository.findRelated(anyLong(), anyString(), anyInt())).thenReturn(List.of());

        service.related("W-1", null);
        service.related("W-1", 999);
        service.related("W-1", 0);

        // 省略与 0 都落到默认 6（查询时 ×3 取 18），所以是 2 次
        verify(repository, org.mockito.Mockito.times(2)).findRelated(1L, "[\"科幻\"]", 18);
        // 999 先按上限 20 截断，再 ×3
        verify(repository).findRelated(1L, "[\"科幻\"]", 60);
    }

    @Test
    @DisplayName("跨源同名只返回一条，保留排在前面的那条（评分更优）")
    void relatedDedupesSameTitle() {
        when(repository.findByWorkId("W-1")).thenReturn(java.util.Optional.of(
                record(1L, "W-1", "[\"科幻\"]")));
        when(publicUrlResolver.baseUrl()).thenReturn("http://localhost:8080");
        // 同一作品两个来源各一条 + 一条别的。查询按评分降序给，第一条即最优。
        when(repository.findRelated(eq(1L), anyString(), anyInt())).thenReturn(List.of(
                titled(9L, "W-9", "同一作品", "[\"科幻\"]", new BigDecimal("9.0")),
                titled(8L, "W-8", "同一作品", "[\"科幻\"]", new BigDecimal("8.0")),
                titled(7L, "W-7", "别的作品", "[\"科幻\"]", new BigDecimal("7.0"))));

        RelatedWorksDto dto = service.related("W-1", 6);

        assertThat(dto.items()).extracting(WorkSummaryDto::workId)
                .containsExactly("W-9", "W-7");
    }

    @Test
    @DisplayName("去重键做 trim + 小写归一：大小写与空白差异也算同名")
    void relatedDedupeKeyIsNormalized() {
        when(repository.findByWorkId("W-1")).thenReturn(java.util.Optional.of(
                record(1L, "W-1", "[\"科幻\"]")));
        when(publicUrlResolver.baseUrl()).thenReturn("http://localhost:8080");
        when(repository.findRelated(eq(1L), anyString(), anyInt())).thenReturn(List.of(
                titled(9L, "W-9", "Yamato", "[\"科幻\"]", new BigDecimal("9.0")),
                titled(8L, "W-8", " yamato ", "[\"科幻\"]", new BigDecimal("8.0"))));

        RelatedWorksDto dto = service.related("W-1", 6);

        assertThat(dto.items()).extracting(WorkSummaryDto::workId)
                .containsExactly("W-9");
    }

    @Test
    @DisplayName("去重后不足 limit 就少返回几条，不凑数")
    void relatedMayReturnFewerAfterDedupe() {
        when(repository.findByWorkId("W-1")).thenReturn(java.util.Optional.of(
                record(1L, "W-1", "[\"科幻\"]")));
        when(publicUrlResolver.baseUrl()).thenReturn("http://localhost:8080");
        // 三条全是同一个标题：去重后只剩 1 条，limit 要 6 也只返回 1
        when(repository.findRelated(eq(1L), anyString(), anyInt())).thenReturn(List.of(
                titled(9L, "W-9", "同一作品", "[\"科幻\"]", new BigDecimal("9.0")),
                titled(8L, "W-8", "同一作品", "[\"科幻\"]", new BigDecimal("8.0")),
                titled(7L, "W-7", "同一作品", "[\"科幻\"]", new BigDecimal("7.0"))));

        RelatedWorksDto dto = service.related("W-1", 6);

        assertThat(dto.items()).hasSize(1);
    }

    @Test
    @DisplayName("标签超过 5 个只取前 5 个做匹配，避免命中退化成全站")
    void relatedCapsBasisTags() {
        when(repository.findByWorkId("W-1")).thenReturn(java.util.Optional.of(
                record(1L, "W-1", "[\"a\",\"b\",\"c\",\"d\",\"e\",\"f\",\"g\"]")));
        when(repository.findRelated(anyLong(), anyString(), anyInt())).thenReturn(List.of());

        RelatedWorksDto dto = service.related("W-1", 3);

        assertThat(dto.basisTags()).containsExactly("a", "b", "c", "d", "e");
        verify(repository).findRelated(1L, "[\"a\",\"b\",\"c\",\"d\",\"e\"]", 9);
    }

    @Test
    @DisplayName("作品没有标签：200 + 空结果，不去查库")
    void relatedWithoutTagsReturnsEmpty() {
        when(repository.findByWorkId("W-1")).thenReturn(java.util.Optional.of(
                record(1L, "W-1", null)));

        RelatedWorksDto dto = service.related("W-1", null);

        assertThat(dto.basisTags()).isEmpty();
        assertThat(dto.items()).isEmpty();
        verify(repository, never()).findRelated(anyLong(), anyString(), anyInt());
    }

    @Test
    @DisplayName("作品不存在：404，与详情一致")
    void relatedOnMissingWorkIs404() {
        when(repository.findByWorkId("W-404")).thenReturn(java.util.Optional.empty());

        assertThatThrownBy(() -> service.related("W-404", null))
                .isInstanceOf(ApiException.class)
                .satisfies(ex -> assertThat(((ApiException) ex).code()).isEqualTo(ErrorCode.WORK_NOT_FOUND));
    }

    @Test
    @DisplayName("work_id 格式非法同样 404，不查库")
    void relatedWithInvalidIdIs404() {
        assertThatThrownBy(() -> service.related("x".repeat(65), null))
                .isInstanceOf(ApiException.class)
                .satisfies(ex -> assertThat(((ApiException) ex).code()).isEqualTo(ErrorCode.WORK_NOT_FOUND));

        verify(repository, never()).findByWorkId(anyString());
    }

    private static WorkRecord record(long id, String workId, String tagsJson) {
        return titled(id, workId, "标题 " + workId, tagsJson, new BigDecimal("7.80"));
    }

    /** 指定标题与评分的记录，去重测试要用同名不同 workId 的样本。 */
    private static WorkRecord titled(
            long id, String workId, String title, String tagsJson, BigDecimal rating) {
        return new WorkRecord(
                id, workId, "anime", title, null, 2022,
                "https://example.invalid/cover.jpg", null, null,
                tagsJson,
                rating, "0-10", "otaku_site",
                "otaku_site", "src-" + id, null,
                NOW, NOW);
    }
}

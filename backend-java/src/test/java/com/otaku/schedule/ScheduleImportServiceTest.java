package com.otaku.schedule;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import com.otaku.common.PublicIdGenerator;
import com.otaku.importer.ImportBatchRepository;
import com.otaku.importer.dto.ImportBatchResult;
import com.otaku.importer.dto.ImportItemResult;
import com.otaku.schedule.dto.ScheduleImportRequest;
import com.otaku.schedule.dto.ScheduleImportRequest.Platform;
import com.otaku.schedule.dto.ScheduleImportRequest.ScheduleImportItem;
import com.otaku.work.WorkRecord;
import com.otaku.work.WorkRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.transaction.support.TransactionCallback;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 档期导入的服务层行为。
 *
 * <p>与作品导入的测试同一口径：不连数据库，只钉住「参数怎么解释、边界怎么处理、
 * 幂等与关联是否正确」这类容易回归的逻辑。SQL 正确性由迁移与真实库实测兜底。
 */
@ExtendWith(MockitoExtension.class)
class ScheduleImportServiceTest {

    private static final LocalDateTime NOW = LocalDateTime.parse("2026-10-22T19:00:00");

    @Mock
    private ScheduleRepository scheduleRepository;

    @Mock
    private WorkRepository workRepository;

    @Mock
    private ImportBatchRepository batchRepository;

    @Mock
    private PublicIdGenerator idGenerator;

    @Mock
    private TransactionTemplate transactionTemplate;

    private ScheduleImportService service;

    @BeforeEach
    void setUp() {
        service = new ScheduleImportService(scheduleRepository, workRepository, batchRepository,
                idGenerator, transactionTemplate, new ObjectMapper());
        // 事务模板在测试里直接执行回调，不起真事务。
        // lenient：拒收类用例（校验失败、批次过大）根本走不到事务，
        // strict stubs 会把"没用到"当失败报出来，那是测试基建而不是行为问题。
        org.mockito.Mockito.lenient()
                .when(transactionTemplate.execute(any())).thenAnswer(invocation -> {
            TransactionCallback<?> callback = invocation.getArgument(0);
            return callback.doInTransaction(null);
        });
        org.mockito.Mockito.lenient()
                .when(batchRepository.saveAndRecordRun(any(), anyString(), anyString())).thenReturn(1);
    }

    private static ScheduleImportItem item(
            String sourceId, Integer weekday, String contentId, List<String> tags) {
        return new ScheduleImportItem(
                sourceId, "202504", "标题 " + sourceId, "标题CN " + sourceId, null,
                weekday, "22:00", "4/7周一深夜", "游戏改编动画",
                tags, "https://i0.hdslb.com/x.jpg",
                List.of(new Platform("www.bilibili.com", "https://www.bilibili.com/1")),
                "https://yuc.wiki/202504/", contentId,
                OffsetDateTime.parse("2026-10-20T06:01:50Z"));
    }

    private static ScheduleImportRequest request(ScheduleImportItem... items) {
        return new ScheduleImportRequest(
                "otaku_site-schedule-20261022-abc", "otaku_site",
                OffsetDateTime.parse("2026-10-22T19:00:00Z"), List.of(items));
    }

    @Test
    @DisplayName("新条目入库，content_id 命中本地作品时回填 work_id")
    void insertsAndLinksWork() {
        when(idGenerator.nextScheduleId()).thenReturn("S-test0001");
        when(workRepository.findBySourceKey("otaku_site", "7267"))
                .thenReturn(Optional.of(new WorkRecord(
                        1L, "W-linked", "anime", "已收录", null, null, null, null, null, null, null, null, null, null,
                        null, null, null, "otaku_site", "7267", null, null, null, null)));

        ImportBatchResult result = service.importSchedules(request(item("469", 1, "7267", List.of("科幻"))));

        assertThat(result.counts().inserted()).isEqualTo(1);
        var captor = org.mockito.ArgumentCaptor.forClass(ScheduleRecord.class);
        verify(scheduleRepository).insert(captor.capture());
        assertThat(captor.getValue().scheduleId()).isEqualTo("S-test0001");
        assertThat(captor.getValue().workId()).isEqualTo("W-linked");
    }

    @Test
    @DisplayName("content_id 未命中：work_id 为 null，档期照样入库")
    void insertsWithoutWorkLink() {
        when(idGenerator.nextScheduleId()).thenReturn("S-test0002");
        when(workRepository.findBySourceKey("otaku_site", "9999")).thenReturn(Optional.empty());

        ImportBatchResult result = service.importSchedules(request(item("470", 1, "9999", null)));

        assertThat(result.counts().inserted()).isEqualTo(1);
        var captor = org.mockito.ArgumentCaptor.forClass(ScheduleRecord.class);
        verify(scheduleRepository).insert(captor.capture());
        assertThat(captor.getValue().workId()).isNull();
    }

    @Test
    @DisplayName("content_id 为 null：不查 work 表，work_id 留空")
    void skipsWorkLookupWhenNoContentId() {
        when(idGenerator.nextScheduleId()).thenReturn("S-test0003");

        service.importSchedules(request(item("471", null, null, null)));

        verify(workRepository, never()).findBySourceKey(anyString(), anyString());
    }

    @Test
    @DisplayName("同内容重跑：unchanged，不写库")
    void rerunSameContentIsUnchanged() {
        ScheduleImportItem same = item("469", 1, null, List.of("科幻"));
        ScheduleRecord existing = new ScheduleRecord(
                7L, "S-existing", "otaku_site", "469",
                "202504", "标题 469", "标题CN 469", null,
                1, "22:00", "4/7周一深夜", "游戏改编动画",
                "[\"科幻\"]", "https://i0.hdslb.com/x.jpg",
                "[{\"name\":\"www.bilibili.com\",\"url\":\"https://www.bilibili.com/1\"}]",
                "https://yuc.wiki/202504/", null, null,
                LocalDateTime.parse("2026-10-20T06:01:50"), NOW, NOW);
        when(scheduleRepository.findBySourceKey("otaku_site", "469"))
                .thenReturn(Optional.of(existing));

        ImportBatchResult result = service.importSchedules(request(same));

        assertThat(result.counts().unchanged()).isEqualTo(1);
        verify(scheduleRepository, never()).update(any());
    }

    @Test
    @DisplayName("内容变化：updated")
    void changedContentUpdates() {
        ScheduleRecord existing = new ScheduleRecord(
                7L, "S-existing", "otaku_site", "469",
                "202504", "旧标题", null, null,
                1, "22:00", null, null, null, null, null, null, null, null, null, NOW, NOW);
        when(scheduleRepository.findBySourceKey("otaku_site", "469"))
                .thenReturn(Optional.of(existing));

        ImportBatchResult result = service.importSchedules(request(item("469", 1, null, null)));

        assertThat(result.counts().updated()).isEqualTo(1);
        verify(scheduleRepository).update(any());
    }

    @Test
    @DisplayName("weekday=0 拒收：0 与待定的歧义会进错分组")
    void weekdayZeroIsRejected() {
        ImportBatchResult result = service.importSchedules(request(item("472", 0, null, null)));

        assertThat(result.counts().rejected()).isEqualTo(1);
        assertThat(result.errors().get(0).code()).isEqualTo("INVALID_WEEKDAY");
        verify(scheduleRepository, never()).insert(any());
    }

    @Test
    @DisplayName("weekday=8 越界拒收，null（待定）合法")
    void weekdayOutOfRangeRejectedButNullAllowed() {
        ImportBatchResult bad = service.importSchedules(request(item("473", 8, null, null)));
        assertThat(bad.counts().rejected()).isEqualTo(1);

        when(idGenerator.nextScheduleId()).thenReturn("S-test0004");
        ImportBatchResult ok = service.importSchedules(request(item("474", null, null, null)));
        assertThat(ok.counts().inserted()).isEqualTo(1);
    }

    @Test
    @DisplayName("title_main 缺失拒收；source_id 缺失拒收")
    void requiredFieldsRejected() {
        ScheduleImportItem noTitle = new ScheduleImportItem(
                "475", "202504", "  ", null, null, 1, null, null, null, null, null, null, null, null, null);
        ScheduleImportItem noId = new ScheduleImportItem(
                " ", "202504", "有标题", null, null, 1, null, null, null, null, null, null, null, null, null);

        ImportBatchResult result = service.importSchedules(request(noTitle, noId));

        assertThat(result.counts().rejected()).isEqualTo(2);
        assertThat(result.errors())
                .extracting(ImportItemResult::code)
                .containsExactlyInAnyOrder("TITLE_REQUIRED", "SOURCE_ID_REQUIRED");
    }

    @Test
    @DisplayName("单批超 500 条直接 400，不拆批")
    void batchTooLargeRejected() {
        List<ScheduleImportItem> items = new java.util.ArrayList<>();
        for (int i = 0; i < 501; i++) {
            items.add(item("s" + i, 1, null, null));
        }

        assertThatThrownBy(() -> service.importSchedules(request(items.toArray(ScheduleImportItem[]::new))))
                .isInstanceOf(ApiException.class)
                .satisfies(ex -> assertThat(((ApiException) ex).code()).isEqualTo(ErrorCode.BATCH_TOO_LARGE));
    }

    @Test
    @DisplayName("坏 URL 协议（javascript:）被丢弃而不是入库")
    void badImageUrlDropped() {
        when(idGenerator.nextScheduleId()).thenReturn("S-test0005");
        ScheduleImportItem bad = new ScheduleImportItem(
                "476", "202504", "标题", null, null, 1, null, null, null, null,
                "javascript:alert(1)", null, null, null, null);

        service.importSchedules(request(bad));

        var captor = org.mockito.ArgumentCaptor.forClass(ScheduleRecord.class);
        verify(scheduleRepository).insert(captor.capture());
        assertThat(captor.getValue().imageUrl()).isNull();
    }

    @Test
    @DisplayName("批次结果写进 import_batch（与作品导入同一套记录）")
    void recordsBatchRun() {
        when(idGenerator.nextScheduleId()).thenReturn("S-test0006");

        service.importSchedules(request(item("477", 1, null, null)));

        verify(batchRepository).saveAndRecordRun(any(), eq("otaku_site"), anyString());
    }
}

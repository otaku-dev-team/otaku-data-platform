package com.otaku.importer;

import com.otaku.common.ApiException;
import com.otaku.importer.dto.DeletionRequest;
import com.otaku.importer.dto.DeletionResult;
import com.otaku.importer.dto.ImportBatchRequest;
import com.otaku.importer.dto.ImportBatchRequest.ImportItem;
import com.otaku.work.WorkRecord;
import com.otaku.work.WorkRepository;
import com.otaku.work.WorkService;
import com.otaku.work.dto.WorkDto;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.ActiveProfiles;

import java.util.ArrayList;
import java.util.List;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * 软删（Issue #249 / docs/deletion-semantics-proposal.md）的落库与对外表现，跑在真 MySQL 上。
 *
 * <p>为什么必须连真库：验的是「V17 的列 + 四个查询面的过滤 + 标签反查表 + 复活」这一整条链路。
 * Mock 掉仓储只能证明调用顺序，证明不了「删完之后列表真的少一条、标签计数真的减一」——
 * 而漏掉任何一个面，等于没删。
 */
@SpringBootTest
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class DeletionIntegrationTest {

    private static final String ID_PREFIX = "it-del-";
    private static final String BATCH_PREFIX = "it-del-batch-";
    private static final String SOURCE = "it-del-src";
    private static final String TAG = "软删回归标签";

    @Autowired
    private DeletionService deletionService;

    @Autowired
    private ImportService importService;

    @Autowired
    private WorkRepository repository;

    @Autowired
    private WorkService workService;

    @Autowired
    private JdbcTemplate jdbc;

    @AfterEach
    void cleanUp() {
        jdbc.update("DELETE FROM import_batch_run WHERE batch_id LIKE ?", BATCH_PREFIX + "%");
        jdbc.update("DELETE FROM import_batch WHERE batch_id LIKE ?", BATCH_PREFIX + "%");
        jdbc.update("DELETE FROM work_tag WHERE work_ref IN"
                + " (SELECT id FROM work WHERE source_id LIKE ?)", ID_PREFIX + "%");
        jdbc.update("DELETE FROM work WHERE source_id LIKE ?", ID_PREFIX + "%");
    }

    @Test
    @DisplayName("软删后：列表/搜索/计数都看不见它，详情仍 200 且 deleted=true")
    void deletedWorkDisappearsFromListsButDetailStillAnswers() {
        importTwo("it-del-1", "it-del-2");
        String workId = requireRecord("it-del-1").workId();
        long before = repository.count(null, "%软删用例%", null, null, null);
        assertThat(before).as("前缀应该命中两部").isGreaterThanOrEqualTo(2);

        DeletionResult result = deletionService.delete(deleteRequest("it-del-1"));
        assertThat(result.accepted()).isEqualTo(1);
        assertThat(result.alreadyDeleted()).isZero();
        assertThat(result.unknown()).isZero();

        assertThat(repository.count(null, "%软删用例%", null, null, null))
                .as("总数必须减一，否则分页 total 会说谎").isEqualTo(before - 1);
        assertThat(repository.findPage(null, "%软删用例%", null, null, null, null, 50, 0))
                .extracting(WorkRecord::sourceId)
                .as("列表不能再出现已下架的作品")
                .doesNotContain("it-del-1")
                .contains("it-del-2");

        WorkDto detail = workService.detail(workId);
        assertThat(detail.deleted()).as("详情必须能查到，且带已下架标记（不是 404）").isTrue();
    }

    @Test
    @DisplayName("标签筛选与标签计数也要过滤：标签反查表按 work_tag 直接扫，最容易漏")
    void deletedWorkDisappearsFromTagFilter() {
        importTwo("it-del-1", "it-del-2");
        long before = repository.count(null, null, List.of(TAG), null, null);
        assertThat(before).as("两部都带同一个标签").isGreaterThanOrEqualTo(2);

        deletionService.delete(deleteRequest("it-del-1"));

        assertThat(repository.count(null, null, List.of(TAG), null, null))
                .as("标签筛选的 total 也必须减一").isEqualTo(before - 1);
        assertThat(repository.findPage(null, null, List.of(TAG), null, null, null, 50, 0))
                .extracting(WorkRecord::sourceId)
                .doesNotContain("it-del-1")
                .contains("it-del-2");
    }

    @Test
    @DisplayName("绕过端点直接改库也要挡住：标签查询的过滤是第二道网（不依赖标签表被清干净）")
    void tagFilterHidesRowsSoftDeletedOutsideTheEndpoint() {
        importTwo("it-del-1", "it-del-2");
        // 模拟「有人直接改库下架」（运营手工操作）：work_tag 没被清，JOIN 上的过滤必须兜住。
        jdbc.update("UPDATE work SET deleted_at = NOW(3) WHERE source = ? AND source_id = ?",
                SOURCE, "it-del-1");

        assertThat(repository.findPage(null, null, List.of(TAG), null, null, null, 50, 0))
                .extracting(WorkRecord::sourceId)
                .as("标签查询不能只靠 work_tag 被清理，SQL 过滤要独立成立")
                .doesNotContain("it-del-1")
                .contains("it-del-2");
    }

    @Test
    @DisplayName("重发幂等：已删的计 already_deleted，库里没有的计 unknown，两者都不报错")
    void resubmitIsIdempotent() {
        importTwo("it-del-1", "it-del-2");
        deletionService.delete(deleteRequest("it-del-1"));

        DeletionResult again = deletionService.delete(deleteRequest("it-del-1", "it-del-missing"));

        assertThat(again.accepted()).as("第二次没有新删的行").isZero();
        assertThat(again.alreadyDeleted()).isEqualTo(1);
        assertThat(again.unknown()).as("库里没有这一行只计数，不整批失败").isEqualTo(1);
    }

    @Test
    @DisplayName("只删本来源：另一个 source 下同 source_id 的作品不受影响")
    void deletionNeverCrossesSources() {
        importItem(SOURCE, "it-del-1");
        importItem("it-del-other", "it-del-1");

        deletionService.delete(deleteRequest("it-del-1"));

        assertThat(workService.detail(requireRecord(SOURCE, "it-del-1").workId()).deleted()).isTrue();
        assertThat(workService.detail(requireRecord("it-del-other", "it-del-1").workId()).deleted())
                .as("跨来源误删会把别的站的数据删掉，这条必须一直是 false")
                .isFalse();
    }

    @Test
    @DisplayName("复活：软删行被接口②重新写入 → deleted 转回 false，列表与标签都回来")
    void reimportResurrectsSoftDeletedWork() {
        importTwo("it-del-1", "it-del-2");
        long workRef = requireRecord("it-del-1").id();
        assertThat(tagRows(workRef)).as("导入时标签反查表应有行").isPositive();

        deletionService.delete(deleteRequest("it-del-1"));
        assertThat(tagRows(workRef)).as("下架后标签要摘掉，否则标签计数还在数它").isZero();

        // 源站又把作品放回来了：走正常导入，不是删除端点。
        importItem(SOURCE, "it-del-1");

        WorkDto detail = workService.detail(requireRecord("it-del-1").workId());
        assertThat(detail.deleted()).as("重新导入必须复活，否则「导了却搜不到」且不报错").isFalse();
        assertThat(tagRows(workRef)).as("复活后标签按 tags 列重建").isPositive();
        assertThat(repository.findPage(null, "%软删用例%", null, null, null, null, 50, 0))
                .extracting(WorkRecord::sourceId)
                .contains("it-del-1");
    }

    @Test
    @DisplayName("单批超过 500 条返回 413（与接口②同一上限），不静默截断")
    void rejectsOversizedBatch() {
        List<DeletionRequest.Item> items = new ArrayList<>();
        for (int i = 0; i < DeletionService.MAX_ITEMS_PER_BATCH + 1; i++) {
            items.add(new DeletionRequest.Item("it-del-" + i, null));
        }
        DeletionRequest request = new DeletionRequest(SOURCE, BATCH_PREFIX + "big", items);

        assertThatThrownBy(() -> deletionService.delete(request))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("单批最多");
    }

    // ---- 辅助 ----

    private void importTwo(String... sourceIds) {
        for (String sourceId : sourceIds) {
            importItem(SOURCE, sourceId);
        }
    }

    private void importItem(String source, String sourceId) {
        ImportItem item = new ImportItem(
                sourceId, "anime", "软删用例 " + sourceId, null, null, null,
                List.of(TAG), null, null, null, null, null, null, null, null, null);
        importService.importBatch(new ImportBatchRequest(
                BATCH_PREFIX + sourceId, source, null, List.of(item)));
    }

    private DeletionRequest deleteRequest(String... sourceIds) {
        List<DeletionRequest.Item> items = new ArrayList<>();
        for (String sourceId : sourceIds) {
            items.add(new DeletionRequest.Item(sourceId, "absent_from_snapshot"));
        }
        return new DeletionRequest(SOURCE, BATCH_PREFIX + "del", items);
    }

    private WorkRecord requireRecord(String sourceId) {
        return requireRecord(SOURCE, sourceId);
    }

    private WorkRecord requireRecord(String source, String sourceId) {
        Optional<WorkRecord> record = repository.findBySourceKey(source, sourceId);
        assertThat(record).as("测试前置：%s/%s 应已导入", source, sourceId).isPresent();
        return record.get();
    }

    private int tagRows(long workRef) {
        Integer count = jdbc.queryForObject(
                "SELECT COUNT(*) FROM work_tag WHERE work_ref = ?", Integer.class, workRef);
        return count == null ? 0 : count;
    }
}

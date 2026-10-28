package com.otaku.importer;

import com.otaku.importer.dto.ImportBatchRequest;
import com.otaku.importer.dto.ImportBatchRequest.ImportItem;
import com.otaku.importer.dto.ImportBatchResult;
import com.otaku.importer.dto.ImportItemResult;
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

import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 详情 4 个富字段（Issue #250）的落库语义，跑在真 MySQL 上。
 *
 * <p>为什么必须连真库：验的是「V14 的列 + UPDATE 的 null-不覆盖 + aliases 三态」
 * 这一整条链路；WorkMerger 是纯函数，已有单元测试钉住合并规则，
 * 这里要钉的是 SQL 与 DTO 的接线——Mock 掉仓储就什么也证明不了。
 */
@SpringBootTest
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class WorkRichFieldsIntegrationTest {

    private static final String ID_PREFIX = "it-rich-";
    private static final String BATCH_PREFIX = "it-rich-batch-";
    private static final String SOURCE = "otaku_site";

    @Autowired
    private ImportService importService;

    @Autowired
    private WorkService workService;

    @Autowired
    private JdbcTemplate jdbc;

    @AfterEach
    void cleanUp() {
        jdbc.update("DELETE FROM import_batch_run WHERE batch_id LIKE ?", BATCH_PREFIX + "%");
        jdbc.update("DELETE FROM import_batch WHERE batch_id LIKE ?", BATCH_PREFIX + "%");
        jdbc.update("DELETE FROM work WHERE source_id LIKE ?", ID_PREFIX + "%");
    }

    @Test
    @DisplayName("首轮带值：详情返回 4 个字段，列表响应不含它们")
    void detailReturnsRichFieldsAndListDoesNot() {
        String sourceId = ID_PREFIX + "detail";
        ImportBatchResult result = importService.importBatch(batch("b1", List.of(
                item(sourceId, "新世纪福音战士", "新世紀エヴァンゲリオン",
                        List.of("EVA", "天鹰战士"), "TV", 26))));
        assertThat(result.counts().inserted()).isEqualTo(1);

        String workId = jdbc.queryForObject(
                "SELECT work_id FROM work WHERE source_id = ?", String.class, sourceId);
        WorkDto detail = workService.detail(workId);

        assertThat(detail.titleOriginal()).isEqualTo("新世紀エヴァンゲリオン");
        assertThat(detail.aliases()).containsExactly("EVA", "天鹰战士");
        assertThat(detail.media()).isEqualTo("TV");
        assertThat(detail.episodes()).isEqualTo(26);

        // 列表是高频大数量响应，不因富字段变胖（契约：7 字段不变）。
        var page = workService.list("anime", "新世纪福音战士", null, null, null, 1, 20);
        assertThat(page.items()).hasSize(1);
        var node = com.fasterxml.jackson.databind.json.JsonMapper.builder().build()
                .valueToTree(page.items().get(0));
        assertThat(node.has("title_original")).isFalse();
        assertThat(node.has("aliases")).isFalse();
        assertThat(node.has("media")).isFalse();
        assertThat(node.has("episodes")).isFalse();
    }

    @Test
    @DisplayName("老同步器：4 字段全不传也能导入，且不清空已有值")
    void omittingFieldsKeepsExistingValues() {
        String sourceId = ID_PREFIX + "keep";
        importService.importBatch(batch("b1", List.of(
                item(sourceId, "攻壳机动队", "攻殻機動隊", List.of("GHOST"), "剧场版", 1))));

        ImportBatchResult second = importService.importBatch(batch("b2", List.of(
                item(sourceId, "攻壳机动队", null, null, null, null))));
        assertThat(second.counts().updated()).isZero();
        assertThat(second.counts().unchanged()).isEqualTo(1);

        WorkDto detail = workService.detail(workIdOf(sourceId));
        assertThat(detail.titleOriginal()).isEqualTo("攻殻機動隊");
        assertThat(detail.aliases()).containsExactly("GHOST");
        assertThat(detail.media()).isEqualTo("剧场版");
        assertThat(detail.episodes()).isEqualTo(1);
    }

    @Test
    @DisplayName("aliases 三态：[] 能清空、null 不清空")
    void aliasesThreeStates() {
        String sourceId = ID_PREFIX + "alias";
        importService.importBatch(batch("b1", List.of(
                item(sourceId, "铃音", null, List.of("Lain", "玲音"), null, null))));

        // null = 本次没拿到 → 保留
        importService.importBatch(batch("b2", List.of(
                item(sourceId, "铃音", null, null, null, null))));
        assertThat(workService.detail(workIdOf(sourceId)).aliases())
                .containsExactly("Lain", "玲音");

        // [] = 明确没有 → 清空
        ImportBatchResult cleared = importService.importBatch(batch("b3", List.of(
                item(sourceId, "铃音", null, List.of(), null, null))));
        assertThat(cleared.counts().updated()).isEqualTo(1);
        assertThat(workService.detail(workIdOf(sourceId)).aliases()).isEmpty();
    }

    @Test
    @DisplayName("episodes 越界（0 / >10000）整条拒收 INVALID_EPISODES，同批其它条不受影响")
    void invalidEpisodesRejectsOnlyThatItem() {
        String badZero = ID_PREFIX + "ep0";
        String badHuge = ID_PREFIX + "eplarge";
        String good = ID_PREFIX + "epok";

        ImportBatchResult result = importService.importBatch(batch("b1", List.of(
                item(badZero, "零话", null, null, null, 0),
                item(badHuge, "一万零一话", null, null, null, 10001),
                item(good, "正常话数", null, null, null, 12))));

        assertThat(result.counts().inserted()).isEqualTo(1);
        assertThat(result.counts().rejected()).isEqualTo(2);
        assertThat(result.errors()).filteredOn(e -> ImportItemResult.REJECTED.equals(e.result()))
                .extracting(ImportItemResult::code)
                .containsOnly("INVALID_EPISODES");
        assertThat(workService.detail(workIdOf(good)).episodes()).isEqualTo(12);
        assertThat(jdbc.queryForObject(
                "SELECT COUNT(*) FROM work WHERE source_id IN (?, ?)", Integer.class, badZero, badHuge))
                .isZero();
    }

    @Test
    @DisplayName("幂等：同批重放不因富字段被判 updated")
    void replayIsUnchanged() {
        String sourceId = ID_PREFIX + "idem";
        ImportBatchRequest request = batch("b1", List.of(
                item(sourceId, "千年女优", "千年女優", List.of("Millennium Actress"), "剧场版", 1)));

        assertThat(importService.importBatch(request).counts().inserted()).isEqualTo(1);
        ImportBatchResult replay = importService.importBatch(request);

        assertThat(replay.counts().updated()).isZero();
        assertThat(replay.counts().unchanged()).isEqualTo(1);
    }

    private String workIdOf(String sourceId) {
        return jdbc.queryForObject(
                "SELECT work_id FROM work WHERE source_id = ?", String.class, sourceId);
    }

    private static ImportBatchRequest batch(String suffix, List<ImportItem> items) {
        return new ImportBatchRequest(BATCH_PREFIX + suffix, SOURCE,
                OffsetDateTime.now(ZoneOffset.UTC), items);
    }

    private static ImportItem item(String sourceId, String title, String titleOriginal,
                                   List<String> aliases, String media, Integer episodes) {
        return new ImportItem(sourceId, "anime", title, null, null, null, null, null, null,
                titleOriginal, aliases, media, episodes, null, null, null);
    }
}

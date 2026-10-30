package com.otaku.appconfig;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.BooleanNode;
import com.otaku.appconfig.dto.AppConfigDtos.ConfigUpdate;
import com.otaku.common.AdultTags;
import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import com.otaku.importer.ImportService;
import com.otaku.importer.dto.ImportBatchRequest;
import com.otaku.importer.dto.ImportBatchRequest.ImportItem;
import com.otaku.importer.dto.ImportBatchRequest.SourceRating;
import com.otaku.work.WorkService;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.ActiveProfiles;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * 运行期配置：改一条数据就能改变线上行为，**不用发版、不用重启**。
 *
 * <p>验的是这条链路真正接通：写配置 → 快照版本变化 → 成人策略换词 → 全库标记重算 →
 * 列表/详情立刻按新口径走。少任何一环，表现都是「配置改了，线上没反应」。
 *
 * <p>必须连真库：重建逻辑是两条 UPDATE + 一张冗余表的同步，Mock 掉等于没测。
 */
@SpringBootTest
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class AppConfigIntegrationTest {

    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final String ID_PREFIX = "it-cfg-";
    private static final String BATCH_PREFIX = "it-cfg-batch-";

    /** 只有这个用例会用到的自定义成人词，避免撞上真实词表。 */
    private static final String CUSTOM_TAG = "it自制成人词";

    @Autowired
    private AppConfigService config;

    @Autowired
    private AppConfigController publicController;

    @Autowired
    private InternalAppConfigController internalController;

    @Autowired
    private ImportService importService;

    @Autowired
    private WorkService workService;

    @Autowired
    private JdbcTemplate jdbc;

    @AfterEach
    void reset() {
        // 配置是全局状态：跑完必须清干净并按默认值重建标记，否则后面的用例会看到这里的口径
        jdbc.update("DELETE FROM app_config WHERE config_key LIKE 'adult.%' OR config_key LIKE 'it.%'");
        config.reload();
        internalController.rebuildAdultFlags();

        jdbc.update("DELETE FROM work_tag WHERE work_ref IN"
                + " (SELECT id FROM work WHERE source_id LIKE ?)", ID_PREFIX + "%");
        jdbc.update("DELETE FROM work WHERE source_id LIKE ?", ID_PREFIX + "%");
        jdbc.update("DELETE FROM import_batch_run WHERE batch_id LIKE ?", BATCH_PREFIX + "%");
        jdbc.update("DELETE FROM import_batch WHERE batch_id LIKE ?", BATCH_PREFIX + "%");
    }

    @Test
    @DisplayName("公开读接口回显生效值：库里没写过也要能看到当前成人词表")
    void publicConfigExposesEffectiveValues() {
        var cfg = publicController.config();

        assertThat(cfg.values().get("adult.hidden").booleanValue()).isTrue();
        assertThat(cfg.values().get("adult.tags")).hasSize(AdultTags.NAMES.size());
        assertThat(cfg.values().get("adult.title_markers")).hasSize(AdultTags.TITLE_MARKERS.size());
    }

    @Test
    @DisplayName("改成人词表 → 该词的作品立刻被隐藏（列表 / 总数 / 详情一起变）")
    void editingAdultTagsTakesEffectImmediately() {
        importBatch(item("it-cfg-1", "自定义标记测试作品", List.of(CUSTOM_TAG), "7.0"));
        String workId = workIdOf("it-cfg-1");

        assertThat(workService.list(null, null, CUSTOM_TAG, null, null, null, null, 1, 50).total())
                .as("还没把它当成人词，应该看得到").isEqualTo(1);

        List<String> tags = new ArrayList<>(AdultTags.NAMES);
        tags.add(CUSTOM_TAG);
        var result = internalController.update(new ConfigUpdate("adult.tags", MAPPER.valueToTree(tags), "测试：加一个自定义词"));

        assertThat(result.rebuild()).as("改 adult.* 必须顺带重算全库标记").isNotNull();
        assertThat(result.rebuild().hiddenWorks()).isGreaterThanOrEqualTo(1);
        assertThat(workService.list(null, null, CUSTOM_TAG, null, null, null, null, 1, 50).total()).isZero();
        assertThatThrownBy(() -> workService.detail(workId))
                .isInstanceOf(ApiException.class)
                .satisfies(ex -> assertThat(((ApiException) ex).code()).isEqualTo(ErrorCode.WORK_NOT_FOUND));
    }

    @Test
    @DisplayName("总开关关掉 → 整块遮挡下线：作品回来、R18 标签也跟着回来")
    void hiddenSwitchTurnsEverythingOff() {
        importBatch(item("it-cfg-2", "开关测试作品", List.of("R18", "科幻"), "7.0"));
        String workId = workIdOf("it-cfg-2");
        assertThatThrownBy(() -> workService.detail(workId)).isInstanceOf(ApiException.class);

        internalController.update(new ConfigUpdate("adult.hidden", BooleanNode.FALSE, "测试：关掉遮挡"));

        var detail = workService.detail(workId);
        assertThat(detail.tags()).as("遮挡下线后连 tags 都不该再剔除").contains("R18");

        internalController.update(new ConfigUpdate("adult.hidden", BooleanNode.TRUE, "测试：恢复遮挡"));
        assertThatThrownBy(() -> workService.detail(workId)).isInstanceOf(ApiException.class);
    }

    @Test
    @DisplayName("键名不合法要 400，不要把脏键写进库")
    void rejectsInvalidKey() {
        assertThatThrownBy(() -> internalController.update(new ConfigUpdate("Bad Key", MAPPER.valueToTree("x"), null)))
                .isInstanceOf(ApiException.class)
                .satisfies(ex -> assertThat(((ApiException) ex).code()).isEqualTo(ErrorCode.BAD_REQUEST));
        assertThatThrownBy(() -> internalController.update(new ConfigUpdate("ok.key", null, null)))
                .isInstanceOf(ApiException.class);
    }

    // ---------------------------------------------------------------- helpers

    private void importBatch(ImportItem... items) {
        importService.importBatch(new ImportBatchRequest(
                BATCH_PREFIX + UUID.randomUUID(), "otaku_site", null, List.of(items)));
    }

    private static ImportItem item(String sourceId, String title, List<String> tags, String rating) {
        return new ImportItem(
                sourceId, "anime", title, null, null, 2022, tags,
                new SourceRating(new BigDecimal(rating), "0-10", "otaku_site"),
                null, null, null, null, null, null, null, null);
    }

    private String workIdOf(String sourceId) {
        return jdbc.queryForObject("SELECT work_id FROM work WHERE source_id = ?", String.class, sourceId);
    }
}

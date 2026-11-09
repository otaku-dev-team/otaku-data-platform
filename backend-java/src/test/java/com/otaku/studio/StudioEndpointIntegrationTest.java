package com.otaku.studio;

import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import com.otaku.importer.ImportService;
import com.otaku.importer.dto.ImportBatchRequest;
import com.otaku.importer.dto.ImportBatchRequest.ImportItem;
import com.otaku.importer.dto.ImportBatchRequest.SourceRating;
import com.otaku.studio.dto.StudioPageDto;
import com.otaku.work.dto.WorkSummaryDto;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.ActiveProfiles;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * 制作公司页端点（#557）：精确匹配、大小写敏感、排序、分页、404。
 *
 * <p>为什么必须连真库：要验的核心是 **MySQL 的排序规则**——默认 `utf8mb4_0900_ai_ci`
 * 大小写不敏感，`A-1 Pictures` 会匹配到 `a-1 pictures`。这条只能在真库上验，
 * 内存实现（H2 / mock）会给出「都对」的假绿。
 *
 * <p>数据走 {@code ImportService} 而不是直接 INSERT：公司名是导入时写进 `work_studios`
 * 的，直接塞库只能证明查询对，证明不了「导入带进来的公司名能被反查到」。
 */
@SpringBootTest
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class StudioEndpointIntegrationTest {

    private static final String ID_PREFIX = "it-studio-";
    private static final String BATCH_PREFIX = "it-studio-batch-";
    private static final String SOURCE = "otaku_site";
    private static final String STUDIO = "it-studio-京都アニメーション";
    /** 大小写只差一位的第二个名字：用来验「不能 LOWER()」。 */
    private static final String STUDIO_LOWER = "it-studio-kyoani";

    @Autowired
    private StudioService service;

    @Autowired
    private ImportService importService;

    @Autowired
    private JdbcTemplate jdbc;

    @AfterEach
    void cleanUp() {
        jdbc.update("DELETE FROM import_batch_run WHERE batch_id LIKE ?", BATCH_PREFIX + "%");
        jdbc.update("DELETE FROM import_batch WHERE batch_id LIKE ?", BATCH_PREFIX + "%");
        jdbc.update("DELETE FROM work WHERE source_id LIKE ?", ID_PREFIX + "%");
    }

    @Test
    @DisplayName("按名字反查：评分降序、id 降序；只返回这家公司的作品")
    void pageOrdersByRating() {
        importBatch(List.of(
                work("a", "低分作", 7.0, STUDIO),
                work("b", "高分作", 9.0, STUDIO),
                work("c", "别家的", 9.5, STUDIO_LOWER)));

        StudioPageDto page = service.page(STUDIO, 60, 0);

        assertThat(page.name()).isEqualTo(STUDIO);
        assertThat(page.total()).isEqualTo(2);
        assertThat(page.items()).extracting(WorkSummaryDto::title)
                .as("评分降序；另一家公司的作品不混进来")
                .containsExactly("高分作", "低分作");
    }

    @Test
    @DisplayName("大小写敏感：只差一个字母就是另一家（404），不是模糊命中")
    void caseSensitive() {
        importBatch(List.of(work("a", "高分作", 9.0, STUDIO_LOWER)));

        assertThat(service.page(STUDIO_LOWER, 60, 0).total()).isEqualTo(1);
        assertThatThrownBy(() -> service.page(STUDIO_LOWER.toUpperCase(), 60, 0))
                .as("全大写不是同一个名字：默认 ai_ci 排序规则会误命中，这里必须 404")
                .isInstanceOf(ApiException.class)
                .satisfies(ex -> assertThat(((ApiException) ex).code())
                        .isEqualTo(ErrorCode.STUDIO_NOT_FOUND));
    }

    @Test
    @DisplayName("请求里的名字按 NFKC + strip 归一：全角字母 / 全角空格 / 首尾空白都能查到")
    void nameIsNfkcNormalized() {
        String ascii = "it-studio-A1Pictures";
        importBatch(List.of(work("a", "全角测试", 8.0, ascii)));

        // 全角字母数字（Ａ／１）经 NFKC 折回半角；全角空格（U+3000）经 strip 去掉。
        // 这两类在真实输入里都出现过：手机输入法、从网页复制公司名。
        String fullWidth = "　ｉｔ－ｓｔｕｄｉｏ－Ａ１Ｐｉｃｔｕｒｅｓ　";
        StudioPageDto page = service.page(fullWidth.replace('－', '-'), 60, 0);

        assertThat(page.name()).as("回显库里的写法，不是请求里的原始串").isEqualTo(ascii);
        assertThat(page.total()).isEqualTo(1);
    }

    @Test
    @DisplayName("分页：total 是总数，items 受 limit/offset 约束；limit 超上限截断不报错")
    void pagination() {
        importBatch(List.of(
                work("a", "第一部", 9.0, STUDIO),
                work("b", "第二部", 8.0, STUDIO),
                work("c", "第三部", 7.0, STUDIO)));

        StudioPageDto first = service.page(STUDIO, 1, 0);
        assertThat(first.total()).isEqualTo(3);
        assertThat(first.items()).extracting(WorkSummaryDto::title).containsExactly("第一部");

        StudioPageDto second = service.page(STUDIO, 1, 1);
        assertThat(second.total()).as("翻页不改变总数").isEqualTo(3);
        assertThat(second.items()).extracting(WorkSummaryDto::title).containsExactly("第二部");

        StudioPageDto beyond = service.page(STUDIO, 60, 99);
        assertThat(beyond.total()).isEqualTo(3);
        assertThat(beyond.items()).as("越界给空数组，不是 404").isEmpty();

        assertThat(service.page(STUDIO, 9999, 0).items()).hasSize(3);
    }

    @Test
    @DisplayName("已下架的作品不出现，且不计入 total")
    void deletedWorkIsExcluded() {
        importBatch(List.of(
                work("live", "在架", 8.0, STUDIO),
                work("gone", "已下架", 9.0, STUDIO)));
        jdbc.update("UPDATE work SET deleted_at = NOW(3) WHERE source_id = ?", ID_PREFIX + "gone");

        StudioPageDto page = service.page(STUDIO, 60, 0);
        assertThat(page.total()).as("列表与计数同一口径，不能「写 2 部、只显示 1 张」").isEqualTo(1);
        assertThat(page.items()).extracting(WorkSummaryDto::title).containsExactly("在架");
    }

    @Test
    @DisplayName("查不到 → 404 STUDIO_NOT_FOUND（不是空态页）；空名字同样 404")
    void unknownStudioIs404() {
        assertThatThrownBy(() -> service.page("不存在的公司-it-studio", 60, 0))
                .isInstanceOf(ApiException.class)
                .satisfies(ex -> assertThat(((ApiException) ex).code())
                        .isEqualTo(ErrorCode.STUDIO_NOT_FOUND));
        assertThatThrownBy(() -> service.page("   ", 60, 0))
                .isInstanceOf(ApiException.class);
    }

    // ------------------------------------------------------------------

    private ImportItem work(String suffix, String title, double rating, String studio) {
        return new ImportItem(ID_PREFIX + suffix, "anime", title, null, null, 2020, null,
                new SourceRating(BigDecimal.valueOf(rating), "0-10", SOURCE), null,
                null, null, null, null, null, null, List.of(studio));
    }

    private void importBatch(List<ImportItem> items) {
        importService.importBatch(new ImportBatchRequest(
                BATCH_PREFIX + System.nanoTime(), SOURCE, OffsetDateTime.now(ZoneOffset.UTC), items));
    }
}

package com.otaku.person;

import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import com.otaku.importer.ImportService;
import com.otaku.importer.dto.ImportBatchRequest;
import com.otaku.importer.dto.ImportBatchRequest.ImportItem;
import com.otaku.importer.dto.ImportBatchRequest.SourceRating;
import com.otaku.person.dto.PersonDtos.PersonCredit;
import com.otaku.person.dto.PersonDtos.PersonDetail;
import com.otaku.work.WorkRepository;
import com.otaku.work.dto.WorkCharacterDto;
import com.otaku.work.dto.WorkStaffDto;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.ActiveProfiles;

import java.math.BigDecimal;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * 人物页（B2 / #455）在真库上的行为。
 *
 * <p>必须连真库的原因：这条链上有三件只有 MySQL 能验的事——
 * `GROUP_CONCAT(DISTINCT …)` 的合并去重、`UNION ALL` 后按作品分组、
 * 以及 join `work` 做的可见性过滤（成人 / 下架 / 收录范围）。
 * Mock 掉仓储只能证明「调了哪个方法」，证明不了「同一部作品里既配音又制作只出一条」。
 */
@SpringBootTest
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class PersonIntegrationTest {

    private static final String SOURCE = "it-person-src";
    private static final String BATCH = "it-person-batch-";
    /** 带前缀的键：切 v3 数据集后全库都是这种形状，接口不该依赖「里面是数字」。 */
    private static final String PERSON = "bgm:880001";
    private static final String OTHER_PERSON = "bgm:880002";

    @Autowired
    private PersonService service;

    @Autowired
    private ImportService importService;

    @Autowired
    private WorkRepository workRepository;

    @Autowired
    private JdbcTemplate jdbc;

    private String workA;
    private String workB;
    private String workAdult;
    private String workDeleted;

    @BeforeEach
    void setUp() {
        cleanUp();
        // A：8.5 分，同一个人既是导演又配音
        workA = importWork("pa", "人物用例 A", 2021, "8.5", List.of(
                new WorkStaffDto("导演", "测试导演", PERSON)),
                List.of(new WorkCharacterDto("鹿目圆", "测试导演", "main", PERSON)));
        // B：7.0 分，只配音
        workB = importWork("pb", "人物用例 B", 2019, "7.0", List.of(),
                List.of(new WorkCharacterDto("晓美焰", "测试导演", "main", PERSON)));
        // C：9.0 分但成人 → 不该出现（否则评分最高的那条会是个打不开的卡片）
        workAdult = importWork("pc", "人物用例 C", 2022, "9.0", List.of(),
                List.of(new WorkCharacterDto("某角色", "测试导演", null, PERSON)));
        jdbc.update("UPDATE work SET is_adult = 1 WHERE work_id = ?", workAdult);
        // D：6.0 分但已下架 → 不该出现
        workDeleted = importWork("pd", "人物用例 D", 2018, "6.0", List.of(
                new WorkStaffDto("脚本", "测试导演", PERSON)), List.of());
        jdbc.update("UPDATE work SET deleted_at = NOW() WHERE work_id = ?", workDeleted);

        // 另一个人，只为证明不会串
        importWork("pe", "人物用例 E", 2020, "7.5", List.of(),
                List.of(new WorkCharacterDto("无关角色", "别人", null, OTHER_PERSON)));
    }

    @AfterEach
    void cleanUp() {
        jdbc.update("DELETE FROM work_tag WHERE work_ref IN (SELECT id FROM work WHERE source = ?)", SOURCE);
        jdbc.update("DELETE FROM work WHERE source = ?", SOURCE);
        jdbc.update("DELETE FROM people WHERE source = ?", SOURCE);
        jdbc.update("DELETE FROM import_batch_run WHERE batch_id LIKE ?", BATCH + "%");
        jdbc.update("DELETE FROM import_batch WHERE batch_id LIKE ?", BATCH + "%");
    }

    @Test
    @DisplayName("同一部作品里既配音又制作，只出一条；角色与职责各自成列")
    void mergesCastAndCreditIntoOneRow() {
        PersonDetail detail = service.detail(PERSON);

        assertThat(detail.personId()).isEqualTo(PERSON);
        assertThat(detail.personName()).isEqualTo("测试导演");
        assertThat(detail.works()).hasSize(2);
        PersonCredit first = detail.works().get(0);
        assertThat(first.work().title()).isEqualTo("人物用例 A");
        assertThat(first.roles()).containsExactly("导演");
        assertThat(first.characters()).containsExactly("鹿目圆");
    }

    @Test
    @DisplayName("按评分倒序；成人 / 已下架的作品不出现，计数也不含它们")
    void hidesInvisibleWorks() {
        PersonDetail detail = service.detail(PERSON);

        assertThat(detail.works()).extracting(c -> c.work().title())
                .containsExactly("人物用例 A", "人物用例 B");
        assertThat(detail.castCount()).as("配音作品 2 部（A、B），成人那部不算").isEqualTo(2);
        assertThat(detail.creditCount()).as("制作作品 1 部（A），下架那部不算").isEqualTo(1);
    }

    @Test
    @DisplayName("只配音的作品 roles 为空数组，只制作的作品 characters 为空数组")
    void emptySidesAreEmptyArrays() {
        PersonDetail detail = service.detail(PERSON);

        PersonCredit castOnly = detail.works().stream()
                .filter(c -> c.work().title().equals("人物用例 B")).findFirst().orElseThrow();
        assertThat(castOnly.roles()).isEmpty();
        assertThat(castOnly.characters()).containsExactly("晓美焰");
    }

    @Test
    @DisplayName("不会串到别人身上")
    void doesNotLeakOtherPeople() {
        PersonDetail detail = service.detail(PERSON);

        assertThat(detail.works()).extracting(c -> c.work().title())
                .doesNotContain("人物用例 E");
    }

    @Test
    @DisplayName("不存在或格式非法的键：404，不用 400 区分（那等于探测接口）")
    void unknownPersonIsNotFound() {
        assertThatThrownBy(() -> service.detail("bgm:404404"))
                .isInstanceOf(ApiException.class)
                .satisfies(ex -> assertThat(((ApiException) ex).code())
                        .isEqualTo(ErrorCode.PERSON_NOT_FOUND));

        assertThatThrownBy(() -> service.detail("  "))
                .isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> service.detail("x".repeat(200)))
                .isInstanceOf(ApiException.class);
    }

    @Test
    @DisplayName("作品超过 120 部不被截断（曾经按「相关作品」的 30×4 截断）")
    void manyWorksAreNotTruncated() {
        java.util.List<ImportItem> items = new java.util.ArrayList<>();
        for (int i = 0; i < 130; i++) {
            items.add(new ImportItem("person-work-many-" + i, "anime", "批量作品 " + i,
                    null, null, 2020, List.of("人物测试"),
                    new SourceRating(new BigDecimal("7.0"), "0-10", "it"),
                    null, null, List.of(), null, null, List.of(),
                    List.of(new WorkCharacterDto("角色" + i, "批量声优", "main", PERSON)),
                    List.of()));
        }
        importService.importBatch(new ImportBatchRequest(BATCH + "many", SOURCE, null, items));

        PersonDetail detail = service.detail(PERSON);

        // setUp 里 A、B 也是这个人的配音作品 → 130 + 2 = 132
        assertThat(detail.works()).as("超过 120 部时不能被截断").hasSize(132);
        assertThat(detail.castCount()).as("计数与列表一致").isEqualTo(132);
    }

    @Test
    @DisplayName("没有参与作品的人也返回 200 + 空列表（people 有行、关系没有）")
    void personWithoutWorks() {
        jdbc.update("INSERT IGNORE INTO people (source, source_id, name, entity_type) VALUES (?, ?, ?, ?)",
                SOURCE, "bgm:880003", "空人物", "person");

        PersonDetail detail = service.detail("bgm:880003");

        assertThat(detail.works()).isEmpty();
        assertThat(detail.castCount()).isZero();
        assertThat(detail.creditCount()).isZero();
    }

    private String importWork(String suffix, String title, int year, String rating,
                              List<WorkStaffDto> staff, List<WorkCharacterDto> characters) {
        importService.importBatch(new ImportBatchRequest(BATCH + suffix, SOURCE, null, List.of(
                new ImportItem("person-work-" + suffix, "anime", title, null, null, year,
                        List.of("人物测试"), new SourceRating(new BigDecimal(rating), "0-10", "it"),
                        null, null, List.of(), null, null, staff, characters, List.of()))));
        return workRepository.findBySourceKey(SOURCE, "person-work-" + suffix).orElseThrow().workId();
    }
}

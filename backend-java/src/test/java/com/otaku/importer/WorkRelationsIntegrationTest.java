package com.otaku.importer;

import com.otaku.importer.dto.ImportBatchRequest;
import com.otaku.importer.dto.ImportBatchRequest.ImportItem;
import com.otaku.importer.dto.ImportBatchResult;
import com.otaku.work.WorkService;
import com.otaku.work.dto.WorkCharacterDto;
import com.otaku.work.dto.WorkStaffDto;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.ActiveProfiles;

import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 档 B 三块关系数据（Issue #255）：制作人员 / 角色声优 / 制作公司的三态语义与详情装配。
 *
 * <p>为什么必须连真库：验的是「V15 三张表 + 先删后插 + 批量插入 + 关系变更单独计入 updated」，
 * 全是 SQL 语义；Mock 掉仓储就只剩分支覆盖，证明不了「`null` 不清空」这类**静默毁数据**的风险。
 */
@SpringBootTest
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class WorkRelationsIntegrationTest {

    private static final Logger log = LoggerFactory.getLogger(WorkRelationsIntegrationTest.class);
    private static final String ID_PREFIX = "it-rel-";
    private static final String BATCH_PREFIX = "it-rel-batch-";
    private static final String SOURCE = "otaku_site";

    @Autowired
    private ImportService importService;

    @Autowired
    private WorkService workService;

    @Autowired
    private JdbcTemplate jdbc;

    @AfterEach
    void cleanUp() {
        // 外键 ON DELETE CASCADE 会带走三张关系表，这里显式删便于失败时排查。
        jdbc.update("DELETE FROM work_staff WHERE work_ref IN (SELECT id FROM work WHERE source_id LIKE ?)",
                ID_PREFIX + "%");
        jdbc.update("DELETE FROM work_characters WHERE work_ref IN (SELECT id FROM work WHERE source_id LIKE ?)",
                ID_PREFIX + "%");
        jdbc.update("DELETE FROM work_studios WHERE work_ref IN (SELECT id FROM work WHERE source_id LIKE ?)",
                ID_PREFIX + "%");
        jdbc.update("DELETE FROM import_batch_run WHERE batch_id LIKE ?", BATCH_PREFIX + "%");
        jdbc.update("DELETE FROM import_batch WHERE batch_id LIKE ?", BATCH_PREFIX + "%");
        jdbc.update("DELETE FROM work WHERE source_id LIKE ?", ID_PREFIX + "%");
        // people 是全局表（uk: source + source_id），不跟着 work 级联，必须单独清。
        jdbc.update("DELETE FROM people WHERE source_id LIKE ?", ID_PREFIX + "%");
    }

    @Test
    @DisplayName("带三组数组导入：详情按来源顺序返回，person_id / character_type 原样透传")
    void detailReturnsRelationsInSourceOrder() {
        String sourceId = ID_PREFIX + "detail";
        importService.importBatch(batch("b1", List.of(item(sourceId, "EVA",
                List.of(new WorkStaffDto("原作", "庵野秀明", null),
                        new WorkStaffDto("脚本", "薩川昭夫", "p-1")),
                List.of(new WorkCharacterDto("碇シンジ", "緒方恵美", "主角", "p-2"),
                        new WorkCharacterDto("綾波レイ", "林原めぐみ", null, "p-3")),
                List.of("GAINAX", "タツノコプロ")))));

        WorkDetailRelations relations = relationsOf(sourceId);
        assertThat(relations.staff()).extracting(WorkStaffDto::role)
                .containsExactly("原作", "脚本");
        assertThat(relations.staff().get(1).personId()).isEqualTo("p-1");
        assertThat(relations.characters()).extracting(WorkCharacterDto::actor)
                .containsExactly("緒方恵美", "林原めぐみ");
        assertThat(relations.characters().get(1).characterType()).isNull();
        assertThat(relations.studios()).containsExactly("GAINAX", "タツノコプロ");
    }

    @Test
    @DisplayName("三态：null 不动、[] 清空、非空整体替换（不是追加）")
    void threeStateSemantics() {
        String sourceId = ID_PREFIX + "state";
        importService.importBatch(batch("b1", List.of(item(sourceId, "攻壳",
                List.of(new WorkStaffDto("导演", "押井守", null)),
                List.of(new WorkCharacterDto("草薙素子", "田中敦子", null, "p-9")),
                List.of("Production I.G")))));

        // null = 本次没拿到 → 一条都不能动
        ImportBatchResult untouched = importService.importBatch(batch("b2", List.of(
                item(sourceId, "攻壳", null, null, null))));
        assertThat(untouched.counts().updated()).isZero();
        assertThat(untouched.counts().unchanged()).isEqualTo(1);
        assertThat(relationsOf(sourceId).staff()).hasSize(1);

        // 非空 = 整体替换：原来 1 条，替换成 2 条后库里只能有 2 条（不是 3 条）
        ImportBatchResult replaced = importService.importBatch(batch("b3", List.of(
                item(sourceId, "攻壳",
                        List.of(new WorkStaffDto("导演", "押井守", null),
                                new WorkStaffDto("音乐", "川井憲次", null)),
                        null, null))));
        assertThat(replaced.counts().updated()).isEqualTo(1);
        assertThat(relationsOf(sourceId).staff()).extracting(WorkStaffDto::name)
                .containsExactly("押井守", "川井憲次");

        // [] = 明确没有 → 清空；详情里三块都变成 null（不编造空数组）
        importService.importBatch(batch("b4", List.of(item(sourceId, "攻壳",
                List.of(), List.of(), List.of()))));
        WorkDetailRelations cleared = relationsOf(sourceId);
        assertThat(cleared.staff()).isNull();
        assertThat(cleared.characters()).isNull();
        assertThat(cleared.studios()).isNull();
    }

    @Test
    @DisplayName("只改 staff、内容字段不变：计为 updated 而不是 unchanged，updated_at 推进")
    void relationOnlyChangeIsCountedAsUpdated() {
        String sourceId = ID_PREFIX + "touch";
        importService.importBatch(batch("b1", List.of(item(sourceId, "铃音",
                List.of(new WorkStaffDto("导演", "中村隆太郎", null)), null, null))));
        String before = jdbc.queryForObject(
                "SELECT updated_at FROM work WHERE source_id = ?", String.class, sourceId);

        ImportBatchResult result = importService.importBatch(batch("b2", List.of(item(sourceId, "铃音",
                List.of(new WorkStaffDto("导演", "中村隆太郎", null),
                        new WorkStaffDto("脚本", "小中千昭", null)), null, null))));

        assertThat(result.counts().updated()).as("关系变了就必须算 updated").isEqualTo(1);
        assertThat(result.counts().unchanged()).isZero();
        String after = jdbc.queryForObject(
                "SELECT updated_at FROM work WHERE source_id = ?", String.class, sourceId);
        assertThat(after).as("updated_at 要推进，否则详情看不出更新").isNotEqualTo(before);
    }

    @Test
    @DisplayName("幂等：同一批重放（含三组数组）不产生 updated")
    void replayWithRelationsIsUnchanged() {
        String sourceId = ID_PREFIX + "idem";
        ImportBatchRequest request = batch("b1", List.of(item(sourceId, "千年女优",
                List.of(new WorkStaffDto("导演", "今敏", null)),
                List.of(new WorkCharacterDto("藤原千代子", "折笠富美子", "主角", null)),
                List.of("MADHOUSE"))));

        assertThat(importService.importBatch(request).counts().inserted()).isEqualTo(1);
        ImportBatchResult replay = importService.importBatch(request);
        assertThat(replay.counts().updated()).isZero();
        assertThat(replay.counts().unchanged()).isEqualTo(1);
    }

    @Test
    @DisplayName("批量插入：100 部 × 288 条 staff（单部实测上限）= 2.88 万行，一次导入完成")
    void bulkInsertHandlesWorstCaseSize() {
        List<ImportItem> items = new ArrayList<>();
        for (int w = 0; w < 100; w++) {
            List<WorkStaffDto> staff = new ArrayList<>();
            for (int i = 0; i < 288; i++) {
                staff.add(new WorkStaffDto("职位" + i, "人员" + i, null));
            }
            items.add(item(ID_PREFIX + "bulk-" + w, "批量作品 " + w, staff, null, null));
        }

        long start = System.nanoTime();
        ImportBatchResult result = importService.importBatch(batch("bulk", items));
        long elapsedMillis = (System.nanoTime() - start) / 1_000_000;

        assertThat(result.counts().inserted()).isEqualTo(100);
        Integer rows = jdbc.queryForObject("""
                SELECT COUNT(*) FROM work_staff WHERE work_ref IN
                  (SELECT id FROM work WHERE source_id LIKE ?)
                """, Integer.class, ID_PREFIX + "bulk-%");
        assertThat(rows).isEqualTo(100 * 288);
        // 逐条 insert 按实测导入速度约 8 条/秒 → 2.88 万行要 1 小时；批量应在秒级。
        log.info("批量插入实测：28,800 行 staff 耗时 {} ms（{} 行/秒）",
                elapsedMillis, 28_800_000L / Math.max(elapsedMillis, 1));
        assertThat(elapsedMillis)
                .as("逐条 insert 会到小时级；这里只要求「不是逐条」这个量级")
                .isLessThan(60_000);
    }

    @Test
    @DisplayName("people 补壳：staff 取 name、characters 取 actor——person_id 在角色上指声优，不是角色")
    void importCreatesPeopleShells() {
        String sourceId = ID_PREFIX + "people";
        importService.importBatch(batch("p1", List.of(item(sourceId, "EVA 补人",
                List.of(new WorkStaffDto("原作", "庵野秀明", ID_PREFIX + "p-staff-1")),
                List.of(new WorkCharacterDto("碇シンジ", "緒方恵美", "主角", ID_PREFIX + "p-cast-1")),
                null))));

        assertThat(peopleName(ID_PREFIX + "p-staff-1"))
                .as("制作人员的人名取 staff.name").isEqualTo("庵野秀明");
        assertThat(peopleName(ID_PREFIX + "p-cast-1"))
                .as("角色行的 person_id 指声优，名字必须取 actor 而不是角色名").isEqualTo("緒方恵美");
        assertThat(jdbc.queryForObject("SELECT entity_type FROM people WHERE source_id = ?",
                String.class, ID_PREFIX + "p-cast-1")).isEqualTo("person");
    }

    @Test
    @DisplayName("people 补壳幂等且不覆盖：重放不增行，已有规范名不被 credits 写法改写")
    void peopleShellsAreIdempotentAndNeverOverwrite() {
        String keepId = ID_PREFIX + "p-keep";
        jdbc.update("INSERT IGNORE INTO people (source, source_id, name, entity_type)"
                + " VALUES (?, ?, ?, 'person')", SOURCE, keepId, "庵野秀明（规范名）");
        String sourceId = ID_PREFIX + "people-idem";
        ImportBatchRequest request = batch("p2", List.of(item(sourceId, "EVA 幂等",
                List.of(new WorkStaffDto("原作", "庵野 秀明", keepId)), null, null)));

        importService.importBatch(request);
        importService.importBatch(request);

        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM people WHERE source_id = ?",
                Integer.class, keepId)).as("重放不增行").isEqualTo(1);
        assertThat(peopleName(keepId)).as("已有的人名不能被 credits 覆盖").isEqualTo("庵野秀明（规范名）");
    }

    @Test
    @DisplayName("同一个人挂多个职位只建一行；没名字的引用跳过（不留半截名）")
    void duplicateAndNamelessRefsAreHandled() {
        String sourceId = ID_PREFIX + "people-dedup";
        String dupId = ID_PREFIX + "p-dup";
        String blankId = ID_PREFIX + "p-blank";
        importService.importBatch(batch("p3", List.of(item(sourceId, "EVA 去重",
                List.of(new WorkStaffDto("作画监督", "本田雄", dupId),
                        new WorkStaffDto("原画", "本田雄", dupId),
                        new WorkStaffDto("色彩设计", "   ", blankId)),
                null, null))));

        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM people WHERE source_id = ?",
                Integer.class, dupId)).as("同一人多个职位只建一行").isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM people WHERE source_id = ?",
                Integer.class, blankId)).as("没名字就建不出人，跳过而不是存空名").isZero();
    }

    private String peopleName(String sourceId) {
        return jdbc.queryForObject("SELECT name FROM people WHERE source = ? AND source_id = ?",
                String.class, SOURCE, sourceId);
    }

    /** 详情三块的小包装，只在本测试里用。 */
    private record WorkDetailRelations(List<WorkStaffDto> staff,
                                       List<WorkCharacterDto> characters,
                                       List<String> studios) {
    }

    private WorkDetailRelations relationsOf(String sourceId) {
        String workId = jdbc.queryForObject(
                "SELECT work_id FROM work WHERE source_id = ?", String.class, sourceId);
        var detail = workService.detail(workId);
        return new WorkDetailRelations(detail.staff(), detail.characters(), detail.studios());
    }

    private static ImportBatchRequest batch(String suffix, List<ImportItem> items) {
        return new ImportBatchRequest(BATCH_PREFIX + suffix, SOURCE,
                OffsetDateTime.now(ZoneOffset.UTC), items);
    }

    private static ImportItem item(String sourceId, String title, List<WorkStaffDto> staff,
                                   List<WorkCharacterDto> characters, List<String> studios) {
        return new ImportItem(sourceId, "anime", title, null, null, null, null, null, null,
                null, null, null, null, staff, characters, studios);
    }
}

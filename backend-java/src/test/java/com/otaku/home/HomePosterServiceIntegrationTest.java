package com.otaku.home;

import com.otaku.home.dto.HomePosters;
import com.otaku.importer.ImportService;
import com.otaku.importer.dto.ImportBatchRequest;
import com.otaku.importer.dto.ImportBatchRequest.ImportItem;
import com.otaku.importer.dto.ImportBatchRequest.SourceRating;
import com.otaku.work.dto.WorkSummaryDto;
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
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 首页 hero 海报（#561）：候选口径、稳定序、封面判据。
 *
 * <p>为什么必须连真库：这一条验的全是 SQL 语义——按季度筛、JOIN 作品、
 * 按 {@code rating_sort} 排、星期 NULL 沉底、LIMIT 12。mock 仓储只能证明
 * 「Java 循环跑过」，证明不了「顺序对」。
 *
 * <p>为什么封面用**真实磁盘文件**而不是 mock：判据本身是「磁盘上有没有这张图」。
 * mock 掉 {@code isCached} 等于把要验的东西替换成「假设它有图」——
 * 那正是之前 {@code cover_source_url} 非空那种假判据翻车的方式。
 */
@SpringBootTest
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class HomePosterServiceIntegrationTest {

    private static final String ID_PREFIX = "it-poster-";
    private static final String BATCH_PREFIX = "it-poster-batch-";
    private static final String SOURCE = "otaku_site";
    /** 真季度（当前季）。 */
    private static final String SEASON = "202610";
    /** 更早的真季度：它的高分作品不该出现在 hero 里。 */
    private static final String OLD_SEASON = "202607";
    /** 伪季度：字符串排序会排在数字季度前面，必须被跳过。 */
    private static final String PSEUDO_SEASON = "unreleased";

    @Autowired
    private HomePosterService service;

    @Autowired
    private ImportService importService;

    @Autowired
    private JdbcTemplate jdbc;

    @AfterEach
    void cleanUp() {
        jdbc.update("DELETE FROM schedule WHERE schedule_id LIKE ?", ID_PREFIX + "%");
        jdbc.update("DELETE FROM import_batch_run WHERE batch_id LIKE ?", BATCH_PREFIX + "%");
        jdbc.update("DELETE FROM import_batch WHERE batch_id LIKE ?", BATCH_PREFIX + "%");
        jdbc.update("DELETE FROM work WHERE source_id LIKE ?", ID_PREFIX + "%");
    }

    /**
     * 上一轮跑测试时写到磁盘的「不该有图」的封面要清掉。
     *
     * <p>缓存目录是本地文件、不随事务回滚：第一次跑完 {@code withCover(97)} 之后，
     * 后续每一轮都会被上一轮留下的那个文件影响，症状是「只在第二次跑才红」。
     * 所以这里显式清，不靠「跑之前目录是空的」这个假设。
     */
    @BeforeEach
    void clearStaleCovers() {
        deleteCoverFile(97);
    }

    @Test
    @DisplayName("只取最新真季度 + 只取有封面的动画；评分降序；最多 12 条")
    void candidatesComeFromLatestRealSeasonOnly() {
        // 13 部当季动画，分数递减；第 12、13 名用来验截断
        List<ImportItem> items = new ArrayList<>();
        for (int i = 1; i <= 13; i++) {
            items.add(anime("s" + i, "当季第" + i + "部", 9.9 - i * 0.1, withCover(i)));
        }
        // 更早季度的高分作品：不该出现在结果里
        items.add(anime("old", "上季神作", 9.99, withCover(99)));
        // 当季最高分但类型不是动画：不该出现
        items.add(item("comic", "comic", "当季漫画", 9.99, withCover(98)));
        // 当季动画但封面缓存不在盘上：不该出现
        items.add(anime("nocover", "没缓存的番", 9.99, coverUrlOnly(97)));
        // 伪季度里的高分动画：不该出现（「最新季度」若按字符串取最大，就会是它）
        items.add(anime("pseudo", "未定档的高分番", 9.99, withCover(96)));
        importBatch(items);

        schedule("s1", SEASON, 3);
        for (int i = 2; i <= 13; i++) {
            schedule("s" + i, SEASON, (i % 7) + 1);
        }
        schedule("old", OLD_SEASON, 1);
        schedule("comic", SEASON, 2);
        schedule("nocover", SEASON, 5);
        schedule("pseudo", PSEUDO_SEASON, null);

        HomePosters posters = service.posters();

        assertThat(posters.items()).hasSize(12);
        assertThat(posters.items()).extracting(WorkSummaryDto::title)
                .as("评分降序，截断到 12 条；上季作品、非动画、无封面都不在")
                .containsExactly(
                        "当季第1部", "当季第2部", "当季第3部", "当季第4部", "当季第5部",
                        "当季第6部", "当季第7部", "当季第8部", "当季第9部", "当季第10部",
                        "当季第11部", "当季第12部");
    }

    @Test
    @DisplayName("同分时按星期、再按标题排；星期未知沉底——顺序必须稳定")
    void orderIsStableByWeekdayThenTitle() {
        importBatch(List.of(
                anime("b", "B", 8.0, withCover(1)),
                anime("a", "A", 8.0, withCover(2)),
                anime("c", "C", 8.0, withCover(3)),
                anime("unknown", "D", 8.0, withCover(4))));
        schedule("b", SEASON, 5);
        schedule("a", SEASON, 2);
        schedule("c", SEASON, 2);
        schedule("unknown", SEASON, null);

        HomePosters posters = service.posters();
        assertThat(posters.items()).extracting(WorkSummaryDto::title)
                .as("同分（8.0）时：星期 2 的两部按标题 A→C，然后星期 5 的 B，未定档的 D 最后")
                .containsExactly("A", "C", "B", "D");

        assertThat(service.posters().items()).extracting(WorkSummaryDto::workId)
                .as("两次调用顺序必须一致：客户端刷新看到换序就是 bug")
                .isEqualTo(posters.items().stream().map(WorkSummaryDto::workId).toList());
    }

    @Test
    @DisplayName("没有档期 / 当季只有非动画 / 封面缓存不在盘上 → 空数组（不填假数据）")
    void emptyWhenNoCandidates() {
        importBatch(List.of(anime("solo", "没档期的番", 8.5, withCover(1))));

        // 有作品但没有任何档期
        assertThat(service.posters().items()).isEmpty();

        // 当季档期有，但类型不是动画
        jdbc.update("UPDATE work SET work_type = 'comic' WHERE source_id = ?", ID_PREFIX + "solo");
        schedule("solo", SEASON, 1);
        assertThat(service.posters().items()).as("hero 只放动画").isEmpty();

        // 类型改回动画、但封面缓存不在盘上
        jdbc.update("UPDATE work SET work_type = 'anime' WHERE source_id = ?", ID_PREFIX + "solo");
        deleteCoverFile(1);
        assertThat(service.posters().items()).as("封面取不到就不进 hero").isEmpty();
    }

    @Test
    @DisplayName("封面地址有值但缓存文件已丢 → 跳过它，用下一条补位（不返回破图）")
    void staleCacheKeyIsSkipped() {
        importBatch(List.of(
                anime("top", "已缓存丢失的番", 9.9, withCover(11)),
                anime("next", "能取到封面的番", 8.0, withCover(12))));
        schedule("top", SEASON, 1);
        schedule("next", SEASON, 2);
        deleteCoverFile(11);

        assertThat(service.posters().items()).extracting(WorkSummaryDto::title)
                .as("少一条也不返回空白位：有图的那条顶上")
                .containsExactly("能取到封面的番");
    }

    // ------------------------------------------------------------------

    private ImportItem anime(String suffix, String title, double rating, String coverUrl) {
        return item(suffix, "anime", title, rating, coverUrl);
    }

    private ImportItem item(String suffix, String type, String title, double rating, String coverUrl) {
        return new ImportItem(ID_PREFIX + suffix, type, title, null, coverUrl, 2026, null,
                new SourceRating(BigDecimal.valueOf(rating), "0-10", SOURCE), null,
                null, null, null, null, null, null, null);
    }

    private void importBatch(List<ImportItem> items) {
        importService.importBatch(new ImportBatchRequest(
                BATCH_PREFIX + System.nanoTime(), SOURCE, OffsetDateTime.now(ZoneOffset.UTC), items));
    }

    /** 写入一条档期，并把封面「放进磁盘缓存」（按 URL 哈希命名，模拟回源成功后的状态）。 */
    private void schedule(String suffix, String season, Integer weekday) {
        String workId = jdbc.queryForObject("SELECT work_id FROM work WHERE source_id = ?",
                String.class, ID_PREFIX + suffix);
        jdbc.update("INSERT INTO schedule (schedule_id, source, source_id, season_code, title_main,"
                        + " weekday, work_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, NOW(3), NOW(3))",
                ID_PREFIX + season + "-" + suffix, SOURCE, ID_PREFIX + suffix, season,
                "档期-" + suffix, weekday, workId);
    }

    /** 把某条作品的封面写进缓存目录（URL 哈希命名），返回该作品的封面 URL。 */
    private String withCover(int seed) {
        String url = coverUrlOnly(seed);
        try {
            Path dir = Path.of("target/it-covers");
            Files.createDirectories(dir);
            Files.write(dir.resolve(sha256Hex(url) + ".jpg"), new byte[]{(byte) 0xFF, (byte) 0xD8});
        } catch (Exception ex) {
            throw new IllegalStateException("写入封面缓存失败", ex);
        }
        return url;
    }

    /** 只有地址、缓存里没有这张图（模拟「URL 有值但取不到图」）。 */
    private static String coverUrlOnly(int seed) {
        return "https://img.example.test/cover-" + ID_PREFIX + seed + ".jpg";
    }

    private void deleteCoverFile(int seed) {
        String url = "https://img.example.test/cover-" + ID_PREFIX + seed + ".jpg";
        try {
            Files.deleteIfExists(Path.of("target/it-covers").resolve(sha256Hex(url) + ".jpg"));
        } catch (Exception ex) {
            throw new IllegalStateException("删除封面缓存失败", ex);
        }
    }

    private static String sha256Hex(String value) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            return HexFormat.of().formatHex(digest.digest(value.getBytes(StandardCharsets.UTF_8)));
        } catch (Exception ex) {
            throw new IllegalStateException(ex);
        }
    }
}

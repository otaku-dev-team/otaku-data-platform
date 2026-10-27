package com.otaku.importer;

import com.otaku.importer.dto.ImportBatchRequest;
import com.otaku.importer.dto.ImportBatchRequest.ImportItem;
import com.otaku.importer.dto.ImportBatchResult;
import com.otaku.importer.dto.ImportItemResult;
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
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 并发导入的回归测试（issue #81）。
 *
 * <p>为什么必须连真库：这里的缺陷**只在 MySQL 的 REPEATABLE READ 快照语义下出现**。
 * 两个作业同时插入同一 {@code (source, source_id)} 时，后到的一方会撞唯一键；
 * 兜底逻辑在**同一个事务**里重新查一次——但那次查询仍然读事务开始时的快照，
 * 看不到对方刚提交的行，于是退化成 {@code INTERNAL_ERROR / rejected}。
 * Mock 掉仓储、或者换成 H2，都验证不到这一层，所以这个测试刻意走真实 MySQL。
 *
 * <p>没有 IT_DB_PORT 时整个类跳过（普通 {@code mvn test} 不需要数据库）；
 * CI 里由 workflow 注入 {@code IT_DB_PORT=3306} 指向 service 容器，因此每次 PR 都会真跑。
 */
@SpringBootTest
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class ImportConcurrencyIntegrationTest {

    /** 测试数据的 source_id 前缀，收尾按它精确清理。 */
    private static final String ID_PREFIX = "it-conc-";
    private static final String BATCH_PREFIX = "it-conc-batch-";

    @Autowired
    private ImportService importService;

    @Autowired
    private JdbcTemplate jdbc;

    @AfterEach
    void cleanUp() {
        // 先删批次运行明细再删批次（外键级联是兜底，这里显式删便于排查失败用例）
        jdbc.update("DELETE FROM import_batch_run WHERE batch_id LIKE ?", BATCH_PREFIX + "%");
        jdbc.update("DELETE FROM import_batch WHERE batch_id LIKE ?", BATCH_PREFIX + "%");
        jdbc.update("DELETE FROM work WHERE source_id LIKE ?", ID_PREFIX + "%");
    }

    @Test
    @DisplayName("两个作业并发提交同一批：不产生 rejected，且不重复入库")
    void concurrentSameBatchProducesNoRejected() throws Exception {
        List<ImportBatchResult> results = runConcurrently(50, 2);

        int rejected = results.stream().mapToInt(r -> r.counts().rejected()).sum();
        int inserted = results.stream().mapToInt(r -> r.counts().inserted()).sum();

        assertThat(rejected)
                .as("并发写入同一批不该出现 rejected，实际错误明细：%s", errorDetail(results))
                .isZero();
        assertThat(inserted).as("50 条应各插入一次").isEqualTo(50);
        assertThat(countWorks()).as("库内行数应与条数一致（无重复、无丢失）").isEqualTo(50);
    }

    @Test
    @DisplayName("两个作业用不同 batch_id 并发提交同一批：同样不产生 rejected")
    void concurrentDifferentBatchesProduceNoRejected() throws Exception {
        List<ImportBatchResult> results = runConcurrently(50, 2, /* sameBatchId */ false);

        int rejected = results.stream().mapToInt(r -> r.counts().rejected()).sum();

        assertThat(rejected)
                .as("并发写入同一批（不同批次号）不该出现 rejected，实际错误明细：%s", errorDetail(results))
                .isZero();
        assertThat(countWorks()).isEqualTo(50);
    }

    @Test
    @DisplayName("五个作业并发同批：不产生 rejected")
    void fiveConcurrentWritersProduceNoRejected() throws Exception {
        List<ImportBatchResult> results = runConcurrently(100, 5);

        int rejected = results.stream().mapToInt(r -> r.counts().rejected()).sum();

        assertThat(rejected)
                .as("5 路并发不该出现 rejected，实际错误明细：%s", errorDetail(results))
                .isZero();
        assertThat(countWorks()).isEqualTo(100);
    }

    // ---------------------------------------------------------------- helpers

    /**
     * 并发跑同一批数据，用闸门尽量让各方同时进入插入阶段——否则串行执行时永远复现不出来。
     */
    private List<ImportBatchResult> runConcurrently(int size, int concurrency) throws Exception {
        return runConcurrently(size, concurrency, true);
    }

    private List<ImportBatchResult> runConcurrently(int size, int concurrency, boolean sameBatchId)
            throws Exception {
        List<ImportItem> items = items(size);
        String sharedBatchId = BATCH_PREFIX + UUID.randomUUID();

        ExecutorService pool = Executors.newFixedThreadPool(concurrency);
        CountDownLatch ready = new CountDownLatch(concurrency);
        CountDownLatch start = new CountDownLatch(1);
        List<Future<ImportBatchResult>> futures = new ArrayList<>();
        try {
            for (int i = 0; i < concurrency; i++) {
                String batchId = sameBatchId ? sharedBatchId : sharedBatchId + "-" + i;
                futures.add(pool.submit(() -> {
                    ready.countDown();
                    if (!start.await(10, TimeUnit.SECONDS)) {
                        throw new IllegalStateException("并发闸门超时");
                    }
                    return importService.importBatch(
                            new ImportBatchRequest(batchId, "otaku_site", null, items));
                }));
            }
            assertThat(ready.await(10, TimeUnit.SECONDS)).as("所有线程应就绪").isTrue();
            start.countDown();

            List<ImportBatchResult> results = new ArrayList<>();
            for (Future<ImportBatchResult> future : futures) {
                results.add(future.get(60, TimeUnit.SECONDS));
            }
            return results;
        } finally {
            pool.shutdownNow();
        }
    }

    private static List<ImportItem> items(int size) {
        List<ImportItem> items = new ArrayList<>(size);
        for (int i = 0; i < size; i++) {
            items.add(new ImportItem(
                    ID_PREFIX + i,
                    "anime",
                    "并发验证作品 " + i,
                    null,
                    null,
                    null,
                    List.of(),
                    null,
                    null,
                    null,
                    null,
                    null,
                    null,
                    null,
                    null,
                    null));
        }
        return items;
    }

    private int countWorks() {
        Integer count = jdbc.queryForObject(
                "SELECT COUNT(*) FROM work WHERE source_id LIKE ?", Integer.class, ID_PREFIX + "%");
        return count == null ? 0 : count;
    }

    private static String errorDetail(List<ImportBatchResult> results) {
        List<String> details = new ArrayList<>();
        for (ImportBatchResult result : results) {
            for (ImportItemResult error : result.errors()) {
                details.add(error.sourceId() + ":" + error.code() + ":" + error.message());
            }
        }
        return details.isEmpty() ? "无" : String.join(", ", details);
    }
}

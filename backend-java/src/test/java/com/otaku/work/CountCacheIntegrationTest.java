package com.otaku.work;

import com.otaku.importer.ImportService;
import com.otaku.importer.dto.ImportBatchRequest;
import com.otaku.importer.dto.ImportBatchRequest.ImportItem;
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
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 列表总数缓存的端到端行为：**导入之后必须重算**。
 *
 * <p>为什么必须连真库：单测只能证明「缓存命中时不查库」，证明不了
 * 「{@code ImportService} 真的会在写完行之后失效缓存」。这两件事分开看都对、
 * 合起来漏一个，用户看到的就是「导入了 5 条，列表还写着 3 条」——
 * 这种错比慢难查得多，所以用真实 MySQL 走一遍 导入 → 列表 → 再导入 → 再列表。
 *
 * <p>用标题里的独特关键词隔离：{@code q} 命中 LIKE，只统计本用例造的行，
 * 不受库里其它测试数据影响。
 */
@SpringBootTest
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class CountCacheIntegrationTest {

    private static final String ID_PREFIX = "it-cache-";
    private static final String BATCH_PREFIX = "it-cache-batch-";
    /** 标题里的独特关键词，用来把自己造的行圈出来。 */
    private static final String KEYWORD = "ITCACHEKW";

    private static final AtomicInteger SEQ = new AtomicInteger();

    @Autowired
    private ImportService importService;

    @Autowired
    private WorkService workService;

    @Autowired
    private CountCache countCache;

    @Autowired
    private JdbcTemplate jdbc;

    @AfterEach
    void cleanUp() {
        // 别把本用例的缓存留给别的测试
        countCache.invalidateAll();
        jdbc.update("DELETE FROM import_batch_run WHERE batch_id LIKE ?", BATCH_PREFIX + "%");
        jdbc.update("DELETE FROM import_batch WHERE batch_id LIKE ?", BATCH_PREFIX + "%");
        jdbc.update("DELETE FROM work WHERE source_id LIKE ?", ID_PREFIX + "%");
    }

    @Test
    @DisplayName("导入新行之后，列表 total 必须跟着变——缓存不能把旧数字留在那儿")
    void importInvalidatesCachedTotal() {
        importItems("a", 3);
        assertThat(total()).isEqualTo(3);

        // 再读一次：这时走缓存，但结果必须仍然正确
        assertThat(total()).isEqualTo(3);

        importItems("b", 2);
        assertThat(total())
                .as("导入 2 条后必须重算；若返回 3 说明缓存没失效")
                .isEqualTo(5);
    }

    @Test
    @DisplayName("只重跑同一批（unchanged）不改变总数，也不该把结果弄错")
    void reimportingSameBatchKeepsTotal() {
        importItems("c", 3);
        assertThat(total()).isEqualTo(3);

        importItems("c", 3); // 同样的 batch_id + source_id → 全部 unchanged
        assertThat(total()).isEqualTo(3);
    }

    // ---------------------------------------------------------------- helpers

    private long total() {
        return workService.list(null, KEYWORD, null, null, null, null, null, 1, 50).total();
    }

    private void importItems(String tag, int count) {
        List<ImportItem> items = new ArrayList<>(count);
        for (int i = 0; i < count; i++) {
            int seq = tag.equals("c") ? i : SEQ.incrementAndGet();
            items.add(new ImportItem(
                    ID_PREFIX + tag + "-" + seq,
                    "anime",
                    KEYWORD + " 作品 " + tag + seq,
                    null,
                    null,
                    null,
                    List.of(),
                    null,
                    null,
                    null, null, null, null, null, null, null));
        }
        importService.importBatch(new ImportBatchRequest(
                BATCH_PREFIX + tag, "otaku_site", null, items));
    }
}

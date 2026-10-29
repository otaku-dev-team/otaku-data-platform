package com.otaku.work;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.ActiveProfiles;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * V16 的性能守卫：work_tag 必须能以 work_ref 为前缀检索（Issue #270）。
 *
 * <p>为什么值得单测：这个索引缺了不会报错、不会错数据，只会让**每次导入慢 400 ms/部**
 * （实测 DELETE 全表扫 409,398 行）。没有守卫时，下一个人把索引当冗余删掉，
 * 性能会静默退回两小时，而所有功能测试依旧全绿。
 */
@SpringBootTest
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class WorkTagIndexIntegrationTest {

    @Autowired
    private JdbcTemplate jdbc;

    @Test
    @DisplayName("idx_work_tag_ref 存在，且 DELETE ... WHERE work_ref 走它（不是全表扫）")
    void deleteByWorkRefUsesIndex() {
        Integer indexed = jdbc.queryForObject("""
                SELECT COUNT(*) FROM information_schema.statistics
                 WHERE table_schema = DATABASE()
                   AND table_name = 'work_tag'
                   AND index_name = 'idx_work_tag_ref'
                   AND seq_in_index = 1
                   AND column_name = 'work_ref'
                """, Integer.class);
        assertThat(indexed).as("work_ref 必须是索引的第一列，否则删标签会全表扫").isEqualTo(1);

        List<Map<String, Object>> plan = jdbc.queryForList("EXPLAIN DELETE FROM work_tag WHERE work_ref = 1");
        assertThat(plan).hasSize(1);
        assertThat(plan.get(0).get("key")).as("DELETE 必须用上 idx_work_tag_ref").isEqualTo("idx_work_tag_ref");
        assertThat(plan.get(0).get("type")).as("不能是 ALL（全表扫描）").isNotEqualTo("ALL");
    }
}

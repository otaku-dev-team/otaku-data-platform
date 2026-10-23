package com.otaku.article;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;

/**
 * 仓储拼出的 SQL 断言。
 *
 * <p>为什么需要它：这类 SQL 错误单测测不出来、业务代码也测不出来，
 * 只有真的连上 MySQL 执行才暴露——本仓连踩两次：
 * {@code IS NOT DISTINCT FROM} 是 PostgreSQL 方言（MySQL 报 1064）；
 * 换成 {@code <=> NULL} 更隐蔽，右值为 NULL 时它等价于 {@code IS NULL}，
 * 于是「不过滤」变成「只查没分类的那批」，接口照样返 200 + 少量条目。
 *
 * <p>集成测试在 CI 上跳过，就在这里把生成的 SQL 文本钉住，
 * 保证下次改动不会又写错方言。只断言 SQL，不断言结果——
 * 结果由真实库端到端验证（迁移 + 导入 + 列表 + 分类 + 详情）兜底。
 *
 * <p>所有 {@code any()} 都带显式类型：{@code NamedParameterJdbcTemplate.query}
 * 有多个重载，不指定类型时 Mockito 报「引用不明确」。
 */
@ExtendWith(MockitoExtension.class)
class ArticleRepositorySqlTest {

    @Mock
    private NamedParameterJdbcTemplate jdbc;

    private void stubQuery() {
        when_query();
    }

    @SuppressWarnings("unchecked")
    private void when_query() {
        org.mockito.Mockito
                .when(jdbc.query(anyString(),
                        org.mockito.ArgumentMatchers.<MapSqlParameterSource>any(),
                        org.mockito.ArgumentMatchers.<RowMapper<ArticleRecord>>any()))
                .thenReturn(List.of());
    }

    private String capturedListSql() {
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verifyQuery(sql);
        return sql.getValue();
    }

    @SuppressWarnings("unchecked")
    private void verifyQuery(ArgumentCaptor<String> sql) {
        org.mockito.Mockito.verify(jdbc).query(sql.capture(),
                org.mockito.ArgumentMatchers.<MapSqlParameterSource>any(),
                org.mockito.ArgumentMatchers.<RowMapper<ArticleRecord>>any());
    }

    @SuppressWarnings("unchecked")
    private void stubCount() {
        org.mockito.Mockito
                .when(jdbc.queryForObject(anyString(),
                        org.mockito.ArgumentMatchers.<MapSqlParameterSource>any(),
                        org.mockito.ArgumentMatchers.<Class<Long>>eq(Long.class)))
                .thenReturn(0L);
    }

    @SuppressWarnings("unchecked")
    private String capturedCountSql() {
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        org.mockito.Mockito.verify(jdbc).queryForObject(sql.capture(),
                org.mockito.ArgumentMatchers.<MapSqlParameterSource>any(),
                org.mockito.ArgumentMatchers.<Class<Long>>eq(Long.class));
        return sql.getValue();
    }

    @Test
    @DisplayName("不过滤时不带 WHERE：<= NULL 会把列表查成只剩没分类的那批")
    void noCategoryMeansNoWhereClause() {
        stubQuery();
        new ArticleRepository(jdbc).findPage(null, 20, 0);

        assertThat(capturedListSql()).doesNotContain("WHERE");
    }

    @Test
    @DisplayName("有分类时用普通等号，不用 IS NOT DISTINCT FROM（PostgreSQL 方言，MySQL 报 1064）")
    void categoryFilterUsesPlainEquals() {
        stubQuery();
        new ArticleRepository(jdbc).findPage("漫画", 20, 0);

        String sql = capturedListSql();
        assertThat(sql).contains("WHERE category = :category");
        assertThat(sql).doesNotContain("DISTINCT");
    }

    @Test
    @DisplayName("排序是 published_at DESC, id DESC：id 作次级键，否则同一分钟的多条翻页会重复或漏条")
    void ordersByPublishedThenId() {
        stubQuery();
        new ArticleRepository(jdbc).findPage(null, 20, 20);

        String sql = capturedListSql();
        assertThat(sql).contains("ORDER BY published_at DESC, id DESC");
        assertThat(sql).contains("LIMIT :limit OFFSET :offset");
    }

    @Test
    @DisplayName("count 在不过滤时同样不带 WHERE：它和列表必须同一套筛选口径")
    void countWithoutFilterHasNoWhereClause() {
        stubCount();
        new ArticleRepository(jdbc).count(null);

        assertThat(capturedCountSql()).doesNotContain("WHERE");
    }

    @Test
    @DisplayName("count 有分类时带同样的条件")
    void countWithFilter() {
        stubCount();
        new ArticleRepository(jdbc).count("漫画");

        assertThat(capturedCountSql()).contains("WHERE category = :category");
    }
}
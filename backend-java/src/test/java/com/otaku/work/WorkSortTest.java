package com.otaku.work;

import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * sort 参数的解析与白名单。
 *
 * <p>这个测试的重点不是"能解析成功"，而是**外部字符串永远不会进 SQL**：
 * 无论传什么，最终拼进 ORDER BY 的只能是枚举里写死的几个常量之一。
 */
class WorkSortTest {

    @Test
    @DisplayName("省略 / 空串走默认 id，保持第一阶段行为")
    void defaultsToId() {
        assertThat(WorkSort.parse(null)).isEqualTo(WorkSort.ID);
        assertThat(WorkSort.parse("")).isEqualTo(WorkSort.ID);
        assertThat(WorkSort.parse("   ")).isEqualTo(WorkSort.ID);
    }

    @Test
    @DisplayName("大小写与首尾空格都容忍")
    void toleratesCaseAndSpaces() {
        assertThat(WorkSort.parse("rating")).isEqualTo(WorkSort.RATING);
        assertThat(WorkSort.parse("RATING")).isEqualTo(WorkSort.RATING);
        assertThat(WorkSort.parse("  year  ")).isEqualTo(WorkSort.YEAR);
    }

    @Test
    @DisplayName("非法值报 400，而不是静默回退到默认排序")
    void rejectsUnknown() {
        assertThatThrownBy(() -> WorkSort.parse("hot"))
                .isInstanceOf(ApiException.class)
                .satisfies(ex -> assertThat(((ApiException) ex).code()).isEqualTo(ErrorCode.BAD_REQUEST));
        // 拼 SQL 的尝试也必须被当成非法值挡掉
        assertThatThrownBy(() -> WorkSort.parse("rating; DROP TABLE work"))
                .isInstanceOf(ApiException.class);
    }

    @Test
    @DisplayName("排序子句是常量，且都带 id 作次级键（分页稳定性）")
    void orderByFragmentsAreWhitelisted() {
        for (WorkSort sort : WorkSort.values()) {
            assertThat(sort.orderBy()).doesNotContain(":", "--", ";");
        }
        assertThat(WorkSort.RATING.orderBy()).isEqualTo("rating_value DESC, id DESC");
        assertThat(WorkSort.YEAR.orderBy()).isEqualTo("release_year DESC, id DESC");
        assertThat(WorkSort.ID.orderBy()).isEqualTo("id ASC");
    }

    @Test
    @DisplayName("带别名版本：每列都加前缀，方向保留（两段式查询外层用）")
    void aliasedOrderBy() {
        assertThat(WorkSort.RATING.orderBy("w")).isEqualTo("w.rating_value DESC, w.id DESC");
        assertThat(WorkSort.YEAR.orderBy("w")).isEqualTo("w.release_year DESC, w.id DESC");
        assertThat(WorkSort.ID.orderBy("w")).isEqualTo("w.id ASC");
        // 别名传空等价于不带别名，避免拼出 ".id" 这种非法 SQL
        assertThat(WorkSort.ID.orderBy("")).isEqualTo("id ASC");
        assertThat(WorkSort.ID.orderBy(null)).isEqualTo("id ASC");
    }
}

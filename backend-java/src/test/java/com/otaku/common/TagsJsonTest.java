package com.otaku.common;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 回归测试：MySQL 的 JSON 列读回来会带 ", " 分隔符。
 * 不做规范化的话，每次重跑都会判定 tags 变了，验收 D2 会失败（已实测踩过）。
 */
class TagsJsonTest {

    @Test
    @DisplayName("MySQL 读回的空格格式被规范成与写入一致")
    void canonicalisesMysqlFormat() {
        assertThat(TagsJson.canonical("[\"日常\", \"搞笑\"]")).isEqualTo("[\"日常\",\"搞笑\"]");
        assertThat(TagsJson.canonical("[\"日常\",\"搞笑\"]")).isEqualTo("[\"日常\",\"搞笑\"]");
    }

    @Test
    @DisplayName("空数组与 null 语义不混同")
    void keepsEmptyArrayDistinctFromNull() {
        assertThat(TagsJson.canonical("[]")).isEqualTo("[]");
        assertThat(TagsJson.canonical(null)).isNull();
    }

    @Test
    @DisplayName("序列化结果可直接与规范化结果比较")
    void writeIsAlreadyCanonical() {
        String written = TagsJson.write(List.of("日常", "搞笑"));

        assertThat(written).isEqualTo("[\"日常\",\"搞笑\"]");
        assertThat(TagsJson.canonical(written)).isEqualTo(written);
    }
}

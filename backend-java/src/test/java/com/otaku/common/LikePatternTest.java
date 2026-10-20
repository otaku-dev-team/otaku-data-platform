package com.otaku.common;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class LikePatternTest {

    @Test
    @DisplayName("普通关键词包成子串匹配")
    void wrapsPlainKeyword() {
        assertThat(LikePattern.contains("航海王")).isEqualTo("%航海王%");
    }

    @Test
    @DisplayName("用户输入的 % 和 _ 当普通字符，不能变成通配符")
    void escapesWildcards() {
        assertThat(LikePattern.contains("50%")).isEqualTo("%50!%%");
        assertThat(LikePattern.contains("a_b")).isEqualTo("%a!_b%");
    }

    @Test
    @DisplayName("转义符自身也要转义")
    void escapesEscapeChar() {
        assertThat(LikePattern.contains("!")).isEqualTo("%!!%");
    }
}

package com.otaku.common;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 长度按码点算，不按 UTF-16 单元。
 *
 * <p>为什么值得一条专门的测试：{@code String.length()} 对 emoji 返回 2，
 * 而数据库 {@code VARCHAR(1000)} 只算 1。两者不一致时，用户会看到
 * 「才写了 500 个表情就说超过 1000 字」——2026-10-31 线上实测复现。
 */
class TextLengthTest {

    @Test
    @DisplayName("汉字：一个算一个")
    void cjk() {
        assertThat(TextLength.of("评论")).isEqualTo(2);
    }

    @Test
    @DisplayName("emoji 算 1 个，而不是 String.length() 的 2 个")
    void emoji() {
        String emoji = "😀";
        assertThat(emoji).hasSize(2);              // 前提：确实是代理对
        assertThat(TextLength.of(emoji)).isEqualTo(1);
        assertThat(TextLength.of(emoji.repeat(1000))).isEqualTo(1000);
    }

    @Test
    @DisplayName("混合文本按码点累加")
    void mixed() {
        assertThat(TextLength.of("a😀字")).isEqualTo(3);
    }

    @Test
    @DisplayName("null 当 0，不抛 NPE")
    void nullIsZero() {
        assertThat(TextLength.of(null)).isZero();
    }

    @Test
    @DisplayName("组合 emoji 仍按码点算（👨‍👩‍👧 = 5），这是与数据库对齐的取舍")
    void zwjSequenceCountsCodePoints() {
        assertThat(TextLength.of("👨‍👩‍👧")).isEqualTo(5);
    }
}

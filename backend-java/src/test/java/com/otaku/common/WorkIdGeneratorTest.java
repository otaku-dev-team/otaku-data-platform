package com.otaku.common;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.HashSet;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;

class WorkIdGeneratorTest {

    private final WorkIdGenerator generator = new WorkIdGenerator();

    @Test
    @DisplayName("格式为 W- 加 15 位小写 Base32，不含易混字符")
    void hasStableFormat() {
        String id = generator.next();

        assertThat(id).startsWith("W-");
        assertThat(id).hasSize(17);
        assertThat(id.substring(2)).matches("[0-9a-hjkmnp-tv-z]{15}");
    }

    @Test
    @DisplayName("随机生成不重复（10000 次无碰撞）")
    void doesNotCollide() {
        Set<String> seen = new HashSet<>();
        for (int i = 0; i < 10_000; i++) {
            assertThat(seen.add(generator.next())).isTrue();
        }
    }
}

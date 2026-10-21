package com.otaku.common;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.HashSet;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;

class PublicIdGeneratorTest {

    private final PublicIdGenerator generator = new PublicIdGenerator();

    @Test
    @DisplayName("work_id 格式为 W- 加 15 位小写 Base32，不含易混字符")
    void workIdFormat() {
        String id = generator.nextWorkId();

        assertThat(id).startsWith("W-");
        assertThat(id).hasSize(17);
        assertThat(id.substring(2)).matches("[0-9a-hjkmnp-tv-z]{15}");
    }

    @Test
    @DisplayName("user_id 与 work_id 前缀不同、长度一致")
    void userIdFormat() {
        String id = generator.nextUserId();

        assertThat(id).startsWith("U-");
        assertThat(id).hasSize(17);
        assertThat(generator.nextWorkId()).isNotEqualTo(id);
    }

    @Test
    @DisplayName("随机生成不重复（10000 次无碰撞）")
    void doesNotCollide() {
        Set<String> seen = new HashSet<>();
        for (int i = 0; i < 10_000; i++) {
            assertThat(seen.add(generator.nextWorkId())).isTrue();
        }
    }
}

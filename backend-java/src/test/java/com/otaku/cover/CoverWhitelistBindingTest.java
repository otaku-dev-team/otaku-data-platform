package com.otaku.cover;

import com.otaku.config.AppProperties;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 白名单绑定的探针：`app.cover.allowed-hosts` 是 {@code List<String>}，
 * 而线上值来自环境变量里的一个逗号串（`154.8.194.198:8000,bgmimg.anibt.net:443`）。
 *
 * <p>要验的就是「逗号串会不会被拆成两个元素」——不拆的话，每一条都会被精确匹配拒掉，
 * 表现为「配了白名单却全站封面 404」。
 */
class CoverWhitelistBindingTest {

    private final ApplicationContextRunner runner = new ApplicationContextRunner()
            .withUserConfiguration(Config.class);

    @Test
    @DisplayName("逗号分隔的白名单会拆成多个元素")
    void commaSeparatedListIsSplit() {
        runner.withPropertyValues(
                        "app.cover.allowed-hosts=154.8.194.198:8000,bgmimg.anibt.net:443")
                .run(ctx -> assertThat(ctx.getBean(AppProperties.class).getCover().getAllowedHosts())
                        .containsExactly("154.8.194.198:8000", "bgmimg.anibt.net:443"));
    }

    @EnableConfigurationProperties(AppProperties.class)
    static class Config {
    }
}
